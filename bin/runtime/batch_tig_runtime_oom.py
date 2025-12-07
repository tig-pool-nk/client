import argparse
import json
import logging
import os
import subprocess
import sys
import time
from concurrent.futures import (
    ThreadPoolExecutor,
    Future,
    wait,
    ALL_COMPLETED,
    FIRST_EXCEPTION,
)
from typing import Dict, Optional, Set

from watchdog_oom import create_watchdog, BaseWatchdog

logging.basicConfig(
    level=logging.INFO, format="[batch_processor] %(message)s", stream=sys.stdout
)
logger = logging.getLogger(__name__)


def process_single_nonce(
    nonce: int,
    settings_json: str,
    rand_hash: str,
    so_path: str,
    max_fuel: int,
    output_dir: str,
    ptx_path: Optional[str] = None,
    gpu_id: Optional[int] = None,
    data_encrypted: Optional[str] = None,
    hyperparameters: Optional[str] = None,
    timeout: int = 0,
    verbose: bool = False,
    stop_on_error: bool = True,
    watchdog: Optional[BaseWatchdog] = None,
) -> tuple[int, Optional[str]]:
    output_file = f"{output_dir}/{nonce}.json"
    if os.path.exists(output_file):
        if verbose:
            logger.debug(f"nonce {nonce}: already computed")
        return (nonce, None)

    try:
        runtime_cmd = [
            "tig-pool-runtime",
            settings_json,
            rand_hash,
            str(nonce),
            so_path,
            "--fuel",
            str(max_fuel),
            "--output",
            output_dir,
        ]
        if data_encrypted:
            runtime_cmd += ["--data", data_encrypted]
        if hyperparameters:
            runtime_cmd += ["--hyperparameters", hyperparameters]
        if ptx_path:
            runtime_cmd += ["--ptx", ptx_path]
        if gpu_id is not None:
            runtime_cmd += ["--gpu", str(gpu_id)]
        elif ptx_path:
            runtime_cmd += ["--gpu", "0"]

        process = subprocess.Popen(
            runtime_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        if watchdog:
            watchdog.set_process(nonce, process)

        try:
            stdout, stderr = process.communicate(
                timeout=timeout if timeout > 0 else None
            )
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise

        if process.returncode in (-15, -9):
            return (nonce, "killed_by_oom")

        if verbose:
            logger.debug(f"nonce {nonce}: exit code {process.returncode}")

        if not os.path.exists(output_file):
            if process.returncode == 0:
                raise Exception("no output")
            stderr_str = stderr.decode(errors="ignore").strip()
            if "OUT_OF_MEMORY" in stderr_str or "out of memory" in stderr_str.lower():
                return (nonce, "cuda_oom")
            raise Exception(f"exit {process.returncode}: {stderr_str}")

        return (nonce, None)

    except Exception as e:
        error_msg = str(e)
        print(f"nonce {nonce}: {error_msg}", file=sys.stderr)
        if stop_on_error:
            with open(f"{output_dir}/result.json", "w") as f:
                json.dump({"error": f"nonce {nonce}: {error_msg}"}, f)
            raise
        return (nonce, error_msg)


def process_runtime_batch(
    start_nonce: int,
    num_nonces: int,
    max_workers: int,
    settings_json: str,
    rand_hash: str,
    so_path: str,
    max_fuel: int,
    output_dir: str,
    ptx_path: Optional[str] = None,
    gpu_id: Optional[int] = None,
    data_encrypted: Optional[str] = None,
    hyperparameters: Optional[str] = None,
    timeout: int = 0,
    verbose: bool = False,
    stop_on_error: bool = True,
    mem_high: float = 0.90,
    mem_low: float = 0.75,
    mem_interval: float = 0.05,
    disable_oom: bool = False,
) -> int:
    try:
        os.makedirs(output_dir, exist_ok=True)
    except PermissionError:
        if not os.path.exists(output_dir):
            logger.error(f"Cannot create output directory: {output_dir}")
            return 0

    watchdog = create_watchdog(gpu_id, mem_high, mem_low, mem_interval, disable_oom)
    watchdog.start()

    success_count = 0
    errors = {}
    pending_nonces = set(range(start_nonce, start_nonce + num_nonces))
    completed_nonces: Set[int] = set()
    batch_start_time = time.time() if timeout > 0 else None
    futures_map: Dict[Future, int] = {}

    try:
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            while (
                pending_nonces
                or futures_map
                or watchdog.get_pending_restart_count() > 0
            ):
                if batch_start_time and (time.time() - batch_start_time) >= timeout:
                    logger.warning(f"Batch timeout ({timeout}s) reached")
                    break

                for nonce in watchdog.get_nonces_to_restart():
                    if nonce not in completed_nonces:
                        pending_nonces.add(nonce)

                while pending_nonces and len(futures_map) < max_workers:
                    nonce = pending_nonces.pop()
                    future = executor.submit(
                        process_single_nonce,
                        nonce,
                        settings_json,
                        rand_hash,
                        so_path,
                        max_fuel,
                        output_dir,
                        ptx_path,
                        gpu_id,
                        data_encrypted,
                        hyperparameters,
                        timeout,
                        verbose,
                        stop_on_error,
                        watchdog,
                    )
                    futures_map[future] = nonce
                    watchdog.register_task(nonce, future)

                if not futures_map:
                    if watchdog.get_pending_restart_count() > 0:
                        time.sleep(mem_interval * 2)
                        continue
                    break

                wait_timeout = max(mem_interval * 5, 0.05)
                if batch_start_time:
                    remaining = timeout - (time.time() - batch_start_time)
                    if remaining <= 0:
                        break
                    wait_timeout = min(wait_timeout, remaining)

                done, _ = wait(
                    futures_map.keys(),
                    timeout=wait_timeout,
                    return_when=FIRST_EXCEPTION if stop_on_error else ALL_COMPLETED,
                )

                for future in done:
                    nonce = futures_map.pop(future)
                    watchdog.unregister_task(nonce)
                    if future.cancelled():
                        continue
                    try:
                        result_nonce, error_msg = future.result()
                        if error_msg is None:
                            success_count += 1
                            completed_nonces.add(result_nonce)
                        elif error_msg in ("killed_by_oom", "cuda_oom"):
                            watchdog.queue_for_retry(result_nonce)
                        else:
                            errors[result_nonce] = error_msg
                            if not stop_on_error:
                                completed_nonces.add(result_nonce)
                    except Exception as e:
                        if stop_on_error:
                            logger.error(f"Critical exception on nonce {nonce}: {e}")
                            executor.shutdown(wait=False, cancel_futures=True)
                            raise
                        errors[nonce] = str(e)
                        completed_nonces.add(nonce)

    except Exception as e:
        logger.error(f"Batch failed: {e}")
    finally:
        if futures_map:
            logger.info(f"Cancelling {len(futures_map)} remaining tasks")
            for future in futures_map:
                future.cancel()
        watchdog.stop()

    if errors:
        with open(f"{output_dir}/result.json", "w") as f:
            json.dump({"errors": errors}, f)

    logger.info(f"Completed {success_count}/{num_nonces} nonces")
    return success_count


def process_explo_batch(
    start_nonce: int,
    max_workers: int,
    settings_json: str,
    rand_hash: str,
    so_path: str,
    max_fuel: int,
    output_dir: str,
    ptx_path: Optional[str] = None,
    gpu_id: Optional[int] = None,
    data_encrypted: Optional[str] = None,
    hyperparameters: Optional[str] = None,
    timeout: int = 0,
    verbose: bool = False,
    mem_high: float = 0.90,
    mem_low: float = 0.75,
    mem_interval: float = 0.05,
    disable_oom: bool = False,
) -> int:
    if timeout <= 0:
        logger.error("timeout is required in explo mode")
        return 0

    try:
        os.makedirs(output_dir, exist_ok=True)
    except PermissionError:
        if not os.path.exists(output_dir):
            logger.error(f"Cannot create output directory: {output_dir}")
            return 0

    watchdog = create_watchdog(gpu_id, mem_high, mem_low, mem_interval, disable_oom)
    watchdog.start()

    start_time = time.time()
    success_count = 0
    current_nonce = start_nonce
    futures_map: Dict[Future, int] = {}

    try:
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            while len(futures_map) < max_workers:
                future = executor.submit(
                    process_single_nonce,
                    current_nonce,
                    settings_json,
                    rand_hash,
                    so_path,
                    max_fuel,
                    output_dir,
                    ptx_path,
                    gpu_id,
                    data_encrypted,
                    hyperparameters,
                    timeout,
                    verbose,
                    False,
                    watchdog,
                )
                futures_map[future] = current_nonce
                watchdog.register_task(current_nonce, future)
                current_nonce += 1

            while time.time() - start_time < timeout:
                remaining_time = timeout - (time.time() - start_time)
                if remaining_time <= 0:
                    break

                retry_nonces = watchdog.get_nonces_to_restart()
                wait_timeout = max(mem_interval * 5, 0.05)
                done, _ = wait(
                    futures_map.keys(), timeout=min(wait_timeout, remaining_time)
                )

                for future in done:
                    nonce = futures_map.pop(future)
                    watchdog.unregister_task(nonce)
                    if future.cancelled():
                        continue

                    spawn_new = True
                    try:
                        result_nonce, error_msg = future.result()
                        if error_msg is None:
                            success_count += 1
                        elif error_msg in ("killed_by_oom", "cuda_oom"):
                            watchdog.queue_for_retry(result_nonce)
                            spawn_new = False
                    except Exception as e:
                        logger.error(f"nonce {nonce} raised exception: {e}")

                    if spawn_new and time.time() - start_time < timeout:
                        next_nonce = (
                            retry_nonces.pop(0) if retry_nonces else current_nonce
                        )
                        if next_nonce == current_nonce:
                            current_nonce += 1
                        new_future = executor.submit(
                            process_single_nonce,
                            next_nonce,
                            settings_json,
                            rand_hash,
                            so_path,
                            max_fuel,
                            output_dir,
                            ptx_path,
                            gpu_id,
                            data_encrypted,
                            hyperparameters,
                            timeout,
                            verbose,
                            False,
                            watchdog,
                        )
                        futures_map[new_future] = next_nonce
                        watchdog.register_task(next_nonce, new_future)

            if futures_map:
                logger.info(
                    f"Timeout reached, waiting for {len(futures_map)} remaining tasks to finish"
                )
                executor.shutdown(wait=True, cancel_futures=False)

    finally:
        watchdog.stop()

    logger.info(
        f"Completed {success_count} nonces ({current_nonce - start_nonce} attempted in {time.time() - start_time:.1f}s)"
    )
    return success_count


def main():
    parser = argparse.ArgumentParser(
        description="TIG Pool Batch Processor", add_help=False
    )
    parser.add_argument("--start-nonce", type=int, required=True)
    parser.add_argument("--num-nonces", type=int, required=True)
    parser.add_argument("--max-workers", type=int, required=True)
    parser.add_argument("--settings", required=True)
    parser.add_argument("--rand-hash", required=True)
    parser.add_argument("--so-path", required=True)
    parser.add_argument("--max-fuel", type=int, required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--mode", required=True, choices=["runtime", "bench", "explo"])
    parser.add_argument("--ptx", default=None)
    parser.add_argument("--gpu-id", type=int, default=None)
    parser.add_argument("--data", default=None)
    parser.add_argument("--hyperparameters", default=None)
    parser.add_argument("--timeout", type=int, default=0)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--mem-high", type=float, default=90.0)
    parser.add_argument("--mem-low", type=float, default=75.0)
    parser.add_argument("--mem-interval", type=int, default=10)
    parser.add_argument("--no-oom", action="store_true")

    args = parser.parse_args()

    if args.verbose:
        logger.setLevel(logging.DEBUG)

    mem_high = args.mem_high / 100.0
    mem_low = args.mem_low / 100.0
    mem_interval = max(args.mem_interval, 10) / 1000.0

    if mem_low >= mem_high:
        logger.error("mem-low must be less than mem-high")
        sys.exit(1)

    if args.mode == "explo":
        success_count = process_explo_batch(
            args.start_nonce,
            args.max_workers,
            args.settings,
            args.rand_hash,
            args.so_path,
            args.max_fuel,
            args.output_dir,
            args.ptx,
            args.gpu_id,
            args.data,
            args.hyperparameters,
            args.timeout,
            args.verbose,
            mem_high,
            mem_low,
            mem_interval,
            args.no_oom,
        )
        sys.exit(0 if success_count > 0 else 1)
    else:
        success_count = process_runtime_batch(
            args.start_nonce,
            args.num_nonces,
            args.max_workers,
            args.settings,
            args.rand_hash,
            args.so_path,
            args.max_fuel,
            args.output_dir,
            args.ptx,
            args.gpu_id,
            args.data,
            args.hyperparameters,
            args.timeout,
            args.verbose,
            args.mode == "runtime",
            mem_high,
            mem_low,
            mem_interval,
            args.no_oom,
        )
        sys.exit(0 if success_count == args.num_nonces else 1)


if __name__ == "__main__":
    main()
