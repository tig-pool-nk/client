import argparse
import asyncio
import json
import logging
import os
import sys
from typing import Dict, Optional, Set

from watchdog_oom import BaseWatchdog, create_watchdog

logging.basicConfig(
    level=logging.INFO, format="[batch_verifier] %(message)s", stream=sys.stdout
)
logger = logging.getLogger(__name__)


async def verify_nonce(
    nonce: int,
    settings_json: str,
    rand_hash: str,
    output_dir: str,
    ptx_path: Optional[str] = None,
    gpu_id: Optional[int] = None,
    data_encrypted: Optional[str] = None,
    verbose: bool = False,
    watchdog: Optional[BaseWatchdog] = None,
) -> tuple[int, Optional[str]]:
    output_file = f"{output_dir}/{nonce}.json"
    if not os.path.exists(output_file):
        return (nonce, "missing file")

    try:
        verify_cmd = [
            "tig-pool-verifier",
            settings_json,
            rand_hash,
            str(nonce),
            output_file,
        ]
        if data_encrypted:
            verify_cmd += ["--data", data_encrypted]
        if ptx_path:
            verify_cmd += ["--ptx", ptx_path]
        if gpu_id is not None:
            verify_cmd += ["--gpu", str(gpu_id)]

        process = await asyncio.create_subprocess_exec(
            *verify_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        if watchdog:
            watchdog.set_process(nonce, process)

        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=60)
        except asyncio.TimeoutError:
            process.kill()
            await process.communicate()
            raise

        if process.returncode in (-15, -9):
            return (nonce, "killed_by_oom")

        stderr_str = stderr.decode(errors="ignore").strip()
        if "OUT_OF_MEMORY" in stderr_str or "out of memory" in stderr_str.lower():
            return (nonce, "cuda_oom")

        if process.returncode != 0:
            raise Exception(f"exit {process.returncode}: {stderr_str}")

        stdout_str = stdout.decode(errors="ignore").strip()
        last_line = stdout_str.splitlines()[-1] if stdout_str else ""
        if not last_line.startswith("quality: "):
            raise Exception("failed to find quality in output")

        quality = int(last_line[len("quality: ") :])
        if verbose:
            logger.debug(f"nonce {nonce}: quality {quality}")

        with open(output_file, "r") as f:
            d = json.load(f)
            d["quality"] = quality
        with open(output_file, "w") as f:
            json.dump(d, f)

        return (nonce, None)

    except asyncio.CancelledError:
        return (nonce, "killed_by_oom")
    except Exception as e:
        print(f"nonce {nonce}: {e}", file=sys.stderr)
        return (nonce, str(e))


async def verify_batch(
    start_nonce: int,
    num_nonces: int,
    max_workers: int,
    settings_json: str,
    rand_hash: str,
    output_dir: str,
    data_encrypted: Optional[str] = None,
    ptx_path: Optional[str] = None,
    gpu_id: Optional[int] = None,
    verbose: bool = False,
    mem_high: float = 0.90,
    mem_low: float = 0.75,
    mem_interval: float = 0.05,
    disable_oom: bool = False,
) -> bool:
    try:
        os.makedirs(output_dir, exist_ok=True)
    except PermissionError:
        if not os.path.exists(output_dir):
            logger.error(f"Cannot create output directory: {output_dir}")
            return False

    watchdog = create_watchdog(gpu_id, mem_high, mem_low, mem_interval, disable_oom)
    watchdog.start()

    success_count = 0
    errors = {}
    pending_nonces = set(range(start_nonce, start_nonce + num_nonces))
    completed_nonces: Set[int] = set()
    active_tasks: Dict[asyncio.Task, int] = {}
    semaphore = asyncio.Semaphore(max_workers)

    async def run_with_semaphore(nonce: int) -> tuple[int, Optional[str]]:
        async with semaphore:
            return await verify_nonce(
                nonce,
                settings_json,
                rand_hash,
                output_dir,
                ptx_path,
                gpu_id,
                data_encrypted,
                verbose,
                watchdog,
            )

    try:
        while (
            pending_nonces or active_tasks or watchdog.get_pending_restart_count() > 0
        ):
            for nonce in watchdog.get_nonces_to_restart():
                if nonce not in completed_nonces:
                    pending_nonces.add(nonce)

            while pending_nonces and len(active_tasks) < max_workers:
                nonce = pending_nonces.pop()
                task = asyncio.create_task(run_with_semaphore(nonce))
                active_tasks[task] = nonce
                watchdog.register_task(nonce, task)

            if not active_tasks:
                if watchdog.get_pending_restart_count() > 0:
                    await asyncio.sleep(mem_interval * 2)
                    continue
                break

            done, _ = await asyncio.wait(
                active_tasks.keys(),
                timeout=mem_interval * 5,
                return_when=asyncio.FIRST_COMPLETED,
            )

            for task in done:
                nonce = active_tasks.pop(task)
                watchdog.unregister_task(nonce)
                if task.cancelled():
                    continue
                try:
                    result_nonce, error_msg = task.result()
                    if error_msg is None:
                        success_count += 1
                        completed_nonces.add(result_nonce)
                    elif error_msg in ("killed_by_oom", "cuda_oom"):
                        watchdog.queue_for_retry(result_nonce)
                    else:
                        errors[result_nonce] = error_msg
                        completed_nonces.add(result_nonce)
                except asyncio.CancelledError:
                    watchdog.queue_for_retry(nonce)
                except Exception as e:
                    errors[nonce] = str(e)
                    completed_nonces.add(nonce)

    finally:
        if active_tasks:
            logger.info(f"Cancelling {len(active_tasks)} remaining tasks")
            for task in active_tasks:
                task.cancel()
            await asyncio.gather(*active_tasks.keys(), return_exceptions=True)
        watchdog.stop()

    if errors:
        with open(f"{output_dir}/verifier_errors.json", "w") as f:
            json.dump({"errors": errors}, f)

    logger.info(f"Completed {success_count}/{num_nonces} nonces")
    return success_count == num_nonces


def main():
    parser = argparse.ArgumentParser(
        description="TIG Pool Batch Verifier", add_help=False
    )
    parser.add_argument("--start-nonce", type=int, required=True)
    parser.add_argument("--num-nonces", type=int, required=True)
    parser.add_argument("--max-workers", type=int, required=True)
    parser.add_argument("--settings", required=True)
    parser.add_argument("--rand-hash", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--data", default=None)
    parser.add_argument("--ptx", default=None)
    parser.add_argument("--gpu-id", type=int, default=None)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--mem-high", type=float, default=90.0)
    parser.add_argument("--mem-low", type=float, default=75.0)
    parser.add_argument("--mem-interval", type=int, default=50)
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

    success = asyncio.run(
        verify_batch(
            args.start_nonce,
            args.num_nonces,
            args.max_workers,
            args.settings,
            args.rand_hash,
            args.output_dir,
            args.data,
            args.ptx,
            args.gpu_id,
            args.verbose,
            mem_high,
            mem_low,
            mem_interval,
            args.no_oom,
        )
    )

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
