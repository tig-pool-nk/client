import argparse
import json
import logging
import os
import subprocess
import sys
import time
from concurrent.futures import ALL_COMPLETED, FIRST_EXCEPTION, ThreadPoolExecutor, wait
from typing import Optional

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

        if gpu_id:
            runtime_cmd += ["--gpu", gpu_id]
        else:
            runtime_cmd += ["--gpu", "0"] if ptx_path else []

        runtime_result = subprocess.run(
            runtime_cmd,
            capture_output=True,
            timeout=timeout if timeout > 0 else None,
        )

        if verbose:
            logger.debug(
                f"nonce {nonce}: runtime exit code {runtime_result.returncode}"
            )

        if not os.path.exists(output_file):
            if runtime_result.returncode == 0:
                raise Exception("no output")
            else:
                raise Exception(
                    f"failed with exit code {runtime_result.returncode}: {runtime_result.stderr.strip()}"
                )

        return (nonce, None)

    except Exception as e:
        error_msg = str(e)
        error_log = f"nonce {nonce}: {error_msg}"
        print(error_log, file=sys.stderr)
        if stop_on_error:
            with open(f"{output_dir}/result.json", "w") as f:
                json.dump({"error": error_log}, f)
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
) -> int:
    try:
        os.makedirs(output_dir, exist_ok=True)
    except PermissionError:
        if not os.path.exists(output_dir):
            logger.error(f"Cannot create output directory: {output_dir}")
            return 0

    success_count = 0
    errors = {}
    futures = []

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        for i in range(num_nonces):
            nonce = start_nonce + i
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
            )
            futures.append(future)

        done, not_done = wait(
            futures,
            timeout=timeout if timeout > 0 else None,
            return_when=FIRST_EXCEPTION if stop_on_error else ALL_COMPLETED,
        )

        exception_raised = False
        if stop_on_error:
            for future in done:
                if future.exception() is not None:
                    logger.error("critical exception detected, stopping pool")
                    exception_raised = True
                    break

            if exception_raised or not_done:
                if not_done:
                    logger.warning(f"{len(not_done)} tasks cancelled")
                executor.shutdown(wait=False, cancel_futures=True)

        for future in futures:
            if future.done() and future.exception() is None:
                try:
                    nonce, error_msg = future.result()
                    if error_msg is None:
                        success_count += 1
                    else:
                        errors[nonce] = error_msg
                except Exception as e:
                    logger.error(f"future raised exception: {e}")

    if errors:
        with open(f"{output_dir}/result.json", "w") as f:
            json.dump({"errors": errors}, f)

    logger.info(f"Completed {success_count}/{num_nonces} nonces successfully")
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

    start_time = time.time()
    success_count = 0
    current_nonce = start_nonce

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {}

        for _ in range(max_workers):
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
            )
            futures[future] = current_nonce
            current_nonce += 1

        while time.time() - start_time < timeout:
            remaining_time = timeout - (time.time() - start_time)
            if remaining_time <= 0:
                break

            done, _ = wait(
                futures.keys(),
                timeout=min(1, remaining_time),
            )

            for future in done:
                nonce = futures.pop(future)
                try:
                    if future.result():
                        success_count += 1
                except Exception as e:
                    logger.error(f"nonce {nonce} raised exception: {e}")

                if time.time() - start_time < timeout:
                    new_future = executor.submit(
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
                    )
                    futures[new_future] = current_nonce
                    current_nonce += 1

        if futures:
            logger.info(f"Timeout reached, cancelling {len(futures)} remaining tasks")
            executor.shutdown(wait=False, cancel_futures=True)

    logger.info(f"Completed {success_count} nonces successfully")
    return success_count


def main():
    parser = argparse.ArgumentParser(description="TIG_pool_custom", add_help=False)

    # Required arguments
    parser.add_argument(
        "--start-nonce", type=int, required=True, help=argparse.SUPPRESS
    )
    parser.add_argument("--num-nonces", type=int, required=True, help=argparse.SUPPRESS)
    parser.add_argument(
        "--max-workers", type=int, required=True, help=argparse.SUPPRESS
    )
    parser.add_argument("--settings", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--rand-hash", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--so-path", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--max-fuel", type=int, required=True, help=argparse.SUPPRESS)
    parser.add_argument("--output-dir", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--mode", required=True, help=argparse.SUPPRESS)

    # Optional arguments
    parser.add_argument("--ptx", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--gpu-id", type=int, default=None, help=argparse.SUPPRESS)
    parser.add_argument("--data", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--hyperparameters", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--timeout", type=int, default=None, help=argparse.SUPPRESS)
    parser.add_argument("--verbose", action="store_true", help=argparse.SUPPRESS)

    args = parser.parse_args()

    if args.verbose:
        logger.setLevel(logging.DEBUG)

    if args.mode != "explo":
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
            stop_on_error=(args.mode == "runtime"),
        )
        if success_count == args.num_nonces:
            sys.exit(0)
        else:
            sys.exit(1)
    else:
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
        )
        if success_count > 0:
            sys.exit(0)
        else:
            sys.exit(1)


if __name__ == "__main__":
    main()
