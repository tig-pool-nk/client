#!/usr/bin/env python3
"""
Batch Processor for TIG Runtime
Processes multiple nonces inside Docker container using ThreadPoolExecutor
This script is designed to run INSIDE the Docker container to minimize docker exec overhead
"""

import argparse
import json
import os
import subprocess
import sys
import logging
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_EXCEPTION
from typing import Optional

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="[batch_processor] %(message)s", stream=sys.stdout
)
logger = logging.getLogger(__name__)

# Global variable to store GPU ID for logging
_gpu_id_str = ""


def process_single_nonce(
    batch_id: str,
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
    verbose: bool = False,
) -> bool:
    """
    Process a single nonce: run tig-runtime then tig-verifier
    Returns True if successful, False otherwise
    """
    output_file = f"{output_dir}/{nonce}.json"

    # Skip if already computed
    if os.path.exists(output_file):
        if verbose:
            logger.debug(f"nonce {nonce}: already computed")
        return True

    # Build tig-runtime command
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

    # Set CUDA_VISIBLE_DEVICES environment variable for this subprocess
    env = os.environ.copy()
    if gpu_id is not None:
        # Restrict to specific GPU - it becomes device 0 after remapping
        env["CUDA_VISIBLE_DEVICES"] = str(gpu_id)
        runtime_cmd += [
            "--gpu",
            "0",
        ]  # Always 0 because of CUDA_VISIBLE_DEVICES remapping
    else:
        # No GPU restriction
        runtime_cmd += ["--gpu", "0"] if ptx_path else []

    # Execute tig-runtime
    try:
        runtime_result = subprocess.run(
            runtime_cmd,
            capture_output=True,
            timeout=300,  # 5 minutes timeout per nonce
            env=env,
        )

        if verbose:
            logger.debug(
                f"batch {batch_id}, nonce {nonce}: runtime exit code {runtime_result.returncode}"
            )

        if not os.path.exists(output_file):
            if runtime_result.returncode == 0:
                raise Exception("no output")
            else:
                raise Exception(
                    f"failed with exit code {runtime_result.returncode}: {runtime_result.stderr.strip()}"
                )

        # Verify solution if output exists
        verify_cmd = ["tig-pool-verifier", settings_json, rand_hash, str(nonce), output_file]

        if data_encrypted:
            verify_cmd += ["--data", data_encrypted]
        if ptx_path:
            verify_cmd += ["--ptx", ptx_path]
        if gpu_id is not None:
            # GPU ID is always 0 due to CUDA_VISIBLE_DEVICES remapping
            verify_cmd += ["--gpu", "0"]

        verify_result = subprocess.run(
            verify_cmd,
            capture_output=True,
            text=True,
            timeout=60,  # 1 minute timeout for verification
            env=env,
        )

        if verify_result.returncode != 0:
            raise Exception(
                f"invalid solution (exit code: {verify_result.returncode}, stderr: {verify_result.stderr.strip()})"
            )

        last_line = verify_result.stdout.strip().splitlines()[-1]
        if not last_line.startswith("quality: "):
            raise Exception("failed to find quality in tig-verifier output")
        try:
            quality = int(last_line[len("quality: ") :])
        except Exception as _:
            raise Exception("failed to parse quality from tig-verifier output")
        logger.debug(f"nonce {nonce} valid solution with quality {quality}")
        with open(output_file, "r") as f:
            d = json.load(f)
            d["quality"] = quality
        with open(output_file, "w") as f:
            json.dump(d, f)

        return True

    except Exception as e:
        msg = f"batch {batch_id}, nonce {nonce}, runtime error: {e}"
        logger.error(msg)
        with open(f"{output_dir}/result.json", "w") as f:
            json.dump({"error": msg}, f)
        raise


def process_batch(
    batch_id: str,
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
    verbose: bool = False,
) -> int:
    """
    Process multiple nonces in parallel using ThreadPoolExecutor
    Returns the number of successfully processed nonces
    """
    global _gpu_id_str

    # Set GPU ID string for logging
    if gpu_id is not None:
        _gpu_id_str = f"[GPU {gpu_id}] "
        logger.info(
            f"{_gpu_id_str}Processing nonces {start_nonce} to {start_nonce + num_nonces - 1} with {max_workers} workers"
        )
    else:
        _gpu_id_str = ""
        logger.info(
            f"Processing nonces {start_nonce} to {start_nonce + num_nonces - 1} with {max_workers} workers"
        )

    # Ensure output directory exists (should already be created by host)
    try:
        os.makedirs(output_dir, exist_ok=True)
    except PermissionError:
        # Directory might already exist from host mount, that's OK
        if not os.path.exists(output_dir):
            logger.error(f"{_gpu_id_str}Cannot create output directory: {output_dir}")
            return 0

    success_count = 0
    futures = []

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        # Submit all nonces to the thread pool
        for i in range(num_nonces):
            nonce = start_nonce + i
            future = executor.submit(
                process_single_nonce,
                batch_id,
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
                verbose,
            )
            futures.append((nonce, future))

        # Wait for futures, stop on first exception
        done, not_done = wait(
            [f for _, f in futures],
            timeout=600,  # 10 minutes total timeout
            return_when=FIRST_EXCEPTION,
        )

        # Check if we stopped due to an exception
        exception_raised = False
        for future in done:
            if future.exception() is not None:
                logger.error(f"{_gpu_id_str}Critical exception detected, stopping pool")
                exception_raised = True
                break

        # Cancel remaining futures if exception occurred
        if exception_raised or not_done:
            if not_done:
                logger.warning(f"{_gpu_id_str}{len(not_done)} tasks cancelled")
            executor.shutdown(wait=False, cancel_futures=True)

        # Count successes from completed futures
        for nonce, future in futures:
            if future.done() and future.exception() is None:
                try:
                    result = future.result()
                    if result:
                        success_count += 1
                except Exception as e:
                    logger.error(f"{_gpu_id_str}nonce {nonce} raised exception: {e}")

    logger.info(
        f"{_gpu_id_str}Completed {success_count}/{num_nonces} nonces successfully"
    )
    return success_count


def main():
    parser = argparse.ArgumentParser(description="TIG_pool_custom", add_help=False)

    # Required arguments
    parser.add_argument("--batch-id", type=str, required=True, help=argparse.SUPPRESS)
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

    # Optional arguments
    parser.add_argument("--ptx-path", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--gpu-id", type=int, default=None, help=argparse.SUPPRESS)
    parser.add_argument("--data", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--hyperparameters", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--verbose", action="store_true", help=argparse.SUPPRESS)

    args = parser.parse_args()

    if args.verbose:
        logger.setLevel(logging.DEBUG)

    # Process the batch
    success_count = process_batch(
        args.batch_id,
        args.start_nonce,
        args.num_nonces,
        args.max_workers,
        args.settings,
        args.rand_hash,
        args.so_path,
        args.max_fuel,
        args.output_dir,
        args.ptx_path,
        args.gpu_id,
        args.data,
        args.hyperparameters,
        args.verbose,
    )

    # Exit with success if all nonces were processed
    if success_count == args.num_nonces:
        logger.info("Batch processing completed successfully")
        sys.exit(0)
    else:
        logger.error(f"Batch processing incomplete: {success_count}/{args.num_nonces}")
        sys.exit(1)


if __name__ == "__main__":
    main()
