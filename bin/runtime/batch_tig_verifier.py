import argparse
import json
import logging
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

logging.basicConfig(
    level=logging.INFO, format="[batch_tig_verifier] %(message)s", stream=sys.stdout
)
logger = logging.getLogger(__name__)


def verify_nonce(
    nonce: int,
    settings_json: str,
    rand_hash: str,
    output_dir: str,
    ptx_path: Optional[str] = None,
    gpu_id: Optional[int] = None,
    data_encrypted: Optional[str] = None,
    verbose: bool = False,
) -> bool:
    output_file = f"{output_dir}/{nonce}.json"
    if not os.path.exists(output_file):
        if verbose:
            logger.warning(f"missing file for nonce {nonce}")
        return False

    try:
        verify_cmd = [
            "tig-verifier",
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
            verify_cmd += ["--gpu", gpu_id]

        verify_result = subprocess.run(
            verify_cmd,
            capture_output=True,
            text=True,
            timeout=60,
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
        msg = f"nonce {nonce}, runtime error: {e}"
        logger.error(msg)
        return False


def verify_batch(
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
) -> int:
    try:
        os.makedirs(output_dir, exist_ok=True)
    except PermissionError:
        if not os.path.exists(output_dir):
            logger.error(f"cannot create output directory: {output_dir}")
            return 0

    success_count = 0
    futures = []

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        for i in range(num_nonces):
            nonce = start_nonce + i
            future = executor.submit(
                verify_nonce,
                nonce,
                settings_json,
                rand_hash,
                output_dir,
                ptx_path,
                gpu_id,
                data_encrypted,
                verbose,
            )
            futures.append(future)

        for future in as_completed(futures, timeout=600):
            try:
                if future.result():
                    success_count += 1
            except Exception as e:
                logger.error(f"future raised exception: {e}")

    logger.info(f"completed {success_count}/{num_nonces} nonces successfully")
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
    parser.add_argument("--output-dir", required=True, help=argparse.SUPPRESS)

    # Optional arguments
    parser.add_argument("--data", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--ptx", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--gpu-id", type=int, default=None, help=argparse.SUPPRESS)
    parser.add_argument("--verbose", action="store_true", help=argparse.SUPPRESS)

    args = parser.parse_args()

    if args.verbose:
        logger.setLevel(logging.DEBUG)

    success_count = verify_batch(
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
    )

    if success_count == args.num_nonces:
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
