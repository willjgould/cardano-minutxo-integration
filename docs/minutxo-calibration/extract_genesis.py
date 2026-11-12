#!/usr/bin/env python3
"""Enumerate initialized mainnet Byron outputs, separately from block outputs.

Genesis has no received transaction-output byte spans. Sizes here are explicitly
constructed minimal Byron encodings, not historical wire measurements. Address
construction follows Cardano.Chain.UTxO.GenesisUTxO, Common.Address,
Common.AddressHash and Common.CBOR in the declared cardano-ledger-specs checkout.
The independent Address2 golden fixture checks the redeem address algorithm.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import zlib

from extract import Reader, integer, require, sequence
from extract_history import describe_historical_output


MAINNET_PROTOCOL_MAGIC = 764824073
MAINNET_GENESIS_OUTPUTS = 14505
MAINNET_GENESIS_LOVELACE = 31112484745000000
# MINUTXO_INTEGRATION_ROOT lets a worktree without checked-out submodules read
# the ledger fixtures and node configuration from another checkout.
ROOT = Path(os.environ.get("MINUTXO_INTEGRATION_ROOT") or Path(__file__).resolve().parents[2]).resolve()
BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def cbor_head(major, value):
    require(isinstance(value, int) and 0 <= value < 2**64, "CBOR uint64 overflow")
    if value < 24:
        return bytes([(major << 5) | value])
    for extra, width in ((24, 1), (25, 2), (26, 4), (27, 8)):
        if value < 1 << (8 * width):
            return bytes([(major << 5) | extra]) + value.to_bytes(width, "big")
    raise ValueError("CBOR uint64 overflow")


def cbor_bytes(value):
    return cbor_head(2, len(value)) + value


def redeem_address(verification_key, attributes=b"\xa0"):
    """Canonical NetworkMainOrStage redeem address; attributes aid golden checks."""
    require(len(verification_key) == 32, "AVVM verification key must be 32 bytes")
    spending_data = b"\x82\x02" + cbor_bytes(verification_key)
    preimage = b"\x83\x02" + spending_data + attributes
    root = hashlib.blake2b(hashlib.sha3_256(preimage).digest(), digest_size=28).digest()
    payload = b"\x83" + cbor_bytes(root) + attributes + b"\x02"
    return b"\x82\xd8\x18" + cbor_bytes(payload) + cbor_head(0, zlib.crc32(payload))


def decode_base58(value):
    require(isinstance(value, str) and value, "empty/non-string base58 address")
    number = 0
    for char in value:
        require(char in BASE58, "invalid base58 address character")
        number = 58 * number + BASE58.index(char)
    padding = len(value) - len(value.lstrip("1"))
    return b"\0" * padding + number.to_bytes((number.bit_length() + 7) // 8, "big")


def validate_address(address):
    """Check the CRC-protected structured address, retaining its original bytes."""
    reader = Reader(address)
    fields = sequence(reader.read(), "Byron address")
    require(reader.pos == len(address) and len(fields) == 2, "invalid Byron address framing")
    tagged, checksum = fields
    require(tagged.major == 6 and tagged.value[0] == 24, "missing Byron address tag 24")
    payload_node = tagged.value[1]
    require(payload_node.major == 2, "Byron address payload is not bytes")
    payload = payload_node.value
    require(zlib.crc32(payload) == integer(checksum, "address CRC32"), "Byron address CRC mismatch")
    inner = Reader(payload)
    content = sequence(inner.read(), "Byron address payload")
    require(inner.pos == len(payload) and len(content) == 3, "invalid Byron payload framing")
    root, attributes, kind = content
    require(root.major == 2 and len(root.value) == 28, "invalid Byron address root")
    require(attributes.major == 5, "Byron address attributes must be a map")
    address_type = integer(kind, "Byron address type")
    require(address_type in (0, 2), "unsupported Byron address type")
    return address_type


def read_golden(path):
    return bytes.fromhex("".join(line.split(":", 1)[1].strip()
                                 for line in path.read_text().splitlines()))


def verify_golden_address():
    """Compare with ledger golden bytes generated independently by Haskell."""
    byron = ROOT / "cardano-ledger-specs/eras/byron"
    key_path = byron / "crypto/golden/RedeemVerificationKey"
    address_path = byron / "ledger/impl/golden/cbor/common/Address2"
    key_reader = Reader(read_golden(key_path))
    key_node = key_reader.read()
    require(key_node.major == 2 and len(key_node.value) == 32, "invalid redeem-key golden")
    # Test.Cardano.Chain.Common.Example.exampleAddress2 uses getBytes 15 32
    # from Test.Cardano.Crypto.CBOR.constantByteString as its HD payload.
    constant = b"Kmyw4lDSE5S4fSH6etNouiXezCyEjKc3tG4ja0kFjO8qzai26ZMPUEJfEy15ox5kJ0uKD"
    attributes = b"\xa1\x01" + cbor_bytes(cbor_bytes(constant[15:47]))
    expected = read_golden(address_path)
    actual = redeem_address(key_node.value, attributes)
    require(actual == expected, "redeem address differs from independent ledger Address2 golden")
    require(validate_address(actual) == 2, "golden address is not a redeem address")
    return {
        "matched": True,
        "address_fixture": str(address_path.relative_to(ROOT)),
        "address_fixture_sha256": hashlib.sha256(address_path.read_bytes()).hexdigest(),
        "verification_key_fixture": str(key_path.relative_to(ROOT)),
        "verification_key_fixture_sha256": hashlib.sha256(key_path.read_bytes()).hexdigest(),
    }


def _genesis_row(address, coin, source_kind, source_identifier):
    require(0 < coin < 2**64, "genesis balance outside positive uint64")
    address_type = validate_address(address)
    coin_cbor = cbor_head(0, coin)
    encoded_output = b"\x82" + address + coin_cbor
    txid = hashlib.blake2b(address, digest_size=32).hexdigest()
    return {
        **describe_historical_output(Reader(encoded_output).read(), 1),
        "byron_address_type": address_type,
        "offset": None,
        "end_offset": None,
        "era": "Genesis",
        "era_tag": -1,
        "chunk": "genesis",
        "slot": 0,
        "block_number": None,
        "transaction_index": None,
        "txid": txid,
        "output_index": 0,
        "is_collateral_return": False,
        "population": "genesis",
        "size_provenance": "constructed_minimal_byron_txout",
        "source_kind": source_kind,
        "source_identifier": source_identifier,
        "constructed_output_cbor_hex": encoded_output.hex(),
    }


def iter_genesis_outputs(path):
    """Yield constructed genesis rows; no row represents received wire bytes."""
    genesis = json.loads(Path(path).read_text())
    require(genesis["protocolConsts"]["protocolMagic"] == MAINNET_PROTOCOL_MAGIC,
            "only mainnet genesis (RequiresNoMagic) is supported")
    seen = set()
    for key_text, balance in sorted(genesis["avvmDistr"].items()):
        key = base64.b64decode(key_text, altchars=b"-_", validate=True)
        address = redeem_address(key)
        row = _genesis_row(address, int(balance), "avvm", key_text)
        require(row["txid"] not in seen, "duplicate genesis address")
        seen.add(row["txid"])
        yield row
    for address_text, balance in sorted(genesis["nonAvvmBalances"].items()):
        address = decode_base58(address_text)
        row = _genesis_row(address, int(balance), "non_avvm", address_text)
        require(row["txid"] not in seen, "duplicate genesis address")
        seen.add(row["txid"])
        yield row


def scan_genesis(path, consume):
    """Apply consume(row) to every initialized output and return provenance."""
    path = Path(path)
    genesis = json.loads(path.read_text())
    canonical_json = json.dumps(genesis, sort_keys=True, separators=(",", ":"),
                                ensure_ascii=False).encode()
    genesis_hash = hashlib.blake2b(canonical_json, digest_size=32).hexdigest()
    config_path = ROOT / "cardano-node/configuration/cardano/mainnet-config.json"
    config = json.loads(config_path.read_text())
    require(config["RequiresNetworkMagic"] == "RequiresNoMagic",
            "declared mainnet configuration unexpectedly requires network magic")
    require(genesis_hash == config["ByronGenesisHash"],
            "genesis hash differs from the declared mainnet configuration")
    golden = verify_golden_address()
    count = total = constructed_bytes = 0
    kinds = {"avvm": 0, "non_avvm": 0}
    checksum = hashlib.sha256()
    for row in iter_genesis_outputs(path):
        count += 1
        total += row["coin"]
        constructed_bytes += row["output_bytes"]
        kinds[row["source_kind"]] += 1
        checksum.update(bytes.fromhex(row["constructed_output_cbor_hex"]))
        consume(row)
    require(count == MAINNET_GENESIS_OUTPUTS, "unexpected mainnet genesis output count")
    require(total == MAINNET_GENESIS_LOVELACE, "unexpected mainnet genesis total balance")
    return {
        "population": "genesis",
        "era": "Genesis",
        "outputs": count,
        "output_counts_by_source": kinds,
        "total_lovelace": total,
        "source": str(path),
        "source_bytes": path.stat().st_size,
        "source_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "canonical_genesis_blake2b256": genesis_hash,
        "declared_config_hash_matched": True,
        "config": str(config_path.relative_to(ROOT)),
        "config_sha256": hashlib.sha256(config_path.read_bytes()).hexdigest(),
        "size_provenance": "constructed_minimal_byron_txout",
        "constructed_output_bytes": constructed_bytes,
        "constructed_outputs_sha256": checksum.hexdigest(),
        "construction_order": "sorted AVVM base64url keys, then sorted non-AVVM base58 addresses",
        "independent_address_golden": golden,
        "historical_wire_bytes": False,
        "note": "Genesis outputs have no creation transaction byte span; the byte-price comparator is counterfactual.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    print(json.dumps(scan_genesis(args.path, lambda _: None), indent=2))
