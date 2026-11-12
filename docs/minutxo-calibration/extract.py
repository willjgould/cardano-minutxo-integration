#!/usr/bin/env python3
"""Measure actual output byte spans in local Conway immutable chunk files.

This is a structural reader, not ledger validation. Use authenticated chain data.
No decoding/re-encoding estimate replaces a received output's original length.

Chunk framing follows docs/minutxo-migration-cost/ScanBench.hs: concatenated
hard-fork [7, [header, tx_bodies, witnesses, auxiliary_data, invalid_indices]].
Output/value shapes follow the minutxo-calculation ledger pin a1631b518:
  eras/babbage/impl/src/Cardano/Ledger/Babbage/TxOut.hs
  eras/mary/impl/src/Cardano/Ledger/Mary/Value.hs
Transaction body keys 1 and 16 are outputs and collateral return respectively.

extract_chunk(path) returns (metadata, rows). Metadata hashes the whole file.
Rows retain file offsets, so original output bytes can be retrieved independently.
Field contributions include a map key where present, or just the list element
for a legacy list output. output_framing_bytes is the residual container framing.
"""

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path


@dataclass(slots=True)
class Node:
    major: int
    value: object
    start: int
    end: int

    @property
    def size(self):
        return self.end - self.start


class Reader:
    """CBOR structural parser retaining byte spans and arbitrary map keys."""

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, count):
        end = self.pos + count
        if end > len(self.data):
            raise ValueError(f"truncated CBOR at offset {self.pos}")
        value = self.data[self.pos:end]
        self.pos = end
        return value

    def at_break(self):
        if self.pos >= len(self.data):
            raise ValueError("unterminated indefinite CBOR container")
        return self.data[self.pos] == 255

    def read(self, depth=0):
        if depth > 256:
            raise ValueError("CBOR nesting exceeds reader limit 256")
        start = self.pos
        head = self.take(1)[0]
        major, additional = head >> 5, head & 31
        if additional < 24:
            number = additional
        elif additional < 28:
            number = int.from_bytes(self.take(1 << (additional - 24)), "big")
        elif additional == 31 and major in (2, 3, 4, 5):
            number = None
        else:
            raise ValueError(f"invalid CBOR initial byte {head:#x} at {start}")

        if major in (0, 1):
            value = number if major == 0 else -1 - number
        elif major in (2, 3):
            if number is None:
                chunks = []
                while not self.at_break():
                    if self.data[self.pos] >> 5 != major or self.data[self.pos] & 31 == 31:
                        raise ValueError("invalid indefinite string chunk")
                    chunks.append(self.read(depth + 1).value)
                self.pos += 1
                value = b"".join(chunks)
            else:
                value = self.take(number)
        elif major in (4, 5):
            value = []

            def item():
                first = self.read(depth + 1)
                return (first, self.read(depth + 1)) if major == 5 else first

            if number is None:
                while not self.at_break():
                    value.append(item())
                self.pos += 1
            else:
                for _ in range(number):
                    value.append(item())
        elif major == 6:
            value = (number, self.read(depth + 1))
        else:
            # Simple values and floating-point bit patterns need no interpretation
            # to preserve their spans while traversing unrelated block fields.
            value = number
        return Node(major, value, start, self.pos)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(node, label):
    require(node.major == 0, f"{label}: expected unsigned integer")
    return node.value


def sequence(node, label):
    require(node.major == 4, f"{label}: expected array")
    return node.value


def integer_map(node, label):
    require(node.major == 5, f"{label}: expected map")
    values, contributions = {}, {}
    for key, value in node.value:
        k = integer(key, f"{label} key")
        require(k not in values, f"{label}: duplicate key {k}")
        values[k] = value
        contributions[k] = key.size + value.size
    return values, contributions


def byte_map(node, label):
    require(node.major == 5, f"{label}: expected map")
    seen = set()
    for key, value in node.value:
        require(key.major == 2, f"{label}: expected byte-string key")
        require(key.value not in seen, f"{label}: duplicate key")
        seen.add(key.value)
        yield key, value


def describe_output(output):
    if output.major == 5:
        fields, contributions = integer_map(output, "output")
        require(set(fields) <= {0, 1, 2, 3}, "unknown output field")
        require({0, 1} <= set(fields), "output missing address/value")
        encoding = "map"
    elif output.major == 4:
        require(len(output.value) in (2, 3), "legacy output length must be 2 or 3")
        fields = dict(enumerate(output.value))
        contributions = {k: v.size for k, v in fields.items()}
        encoding = "list"
    else:
        raise ValueError("unsupported output encoding")

    address, value = fields[0], fields[1]
    require(address.major == 2 and len(address.value) > 0, "invalid address bytes")
    address_tag = address.value[0] >> 4
    address_type = (
        "base" if address_tag <= 3 else
        "pointer" if address_tag <= 5 else
        "enterprise" if address_tag <= 7 else
        "bootstrap" if address_tag == 8 else "unknown"
    )
    require(address_type != "unknown", "unsupported output address type")

    policies = assets = name_bytes = quantity_bytes = multiasset_bytes = 0
    if value.major == 0:
        coin_node = value
    else:
        pair = sequence(value, "value")
        require(len(pair) == 2, "multiasset value length must be 2")
        coin_node, multiasset = pair
        multiasset_bytes = multiasset.size
        for policy, asset_map in byte_map(multiasset, "policies"):
            require(len(policy.value) == 28, "policy ID must be 28 bytes")
            policies += 1
            before = assets
            for name, quantity in byte_map(asset_map, "assets"):
                require(len(name.value) <= 32, "asset name exceeds 32 bytes")
                require(0 < integer(quantity, "asset quantity") < 2**64,
                        "asset quantity outside positive uint64")
                assets += 1
                name_bytes += len(name.value)
                quantity_bytes += quantity.size
            require(assets > before, "empty policy asset map")
        # Conway accepts an empty outer MultiAsset map in [coin, {}]. The
        # stricter nonempty outer-map rule starts at decoder version 12.
    coin = integer(coin_node, "coin")
    require(coin < 2**64, "coin outside uint64")

    datum_type = "none"
    if 2 in fields:
        datum = fields[2]
        if encoding == "list":
            require(datum.major == 2 and len(datum.value) == 32, "invalid legacy datum hash")
            datum_type = "hash"
        else:
            pair = sequence(datum, "datum option")
            require(len(pair) == 2, "datum option length must be 2")
            kind = integer(pair[0], "datum option kind")
            require(kind in (0, 1), "unknown datum option")
            if kind == 0:
                require(pair[1].major == 2 and len(pair[1].value) == 32, "invalid datum hash")
            else:
                require(pair[1].major == 6 and pair[1].value[0] == 24
                        and pair[1].value[1].major == 2, "invalid inline datum wrapper")
            datum_type = "hash" if kind == 0 else "inline"
    if 3 in fields:
        script = fields[3]
        require(script.major == 6 and script.value[0] == 24
                and script.value[1].major == 2, "invalid reference script wrapper")

    return {
        "output_bytes": output.size,
        "num_assets": assets,
        "num_policies": policies,
        "asset_name_bytes": name_bytes,
        "asset_quantity_encoding_bytes": quantity_bytes,
        "coin": coin,
        "coin_encoding_bytes": coin_node.size,
        "value_encoding_bytes": value.size,
        "value_contribution_bytes": contributions[1],
        "multiasset_encoding_bytes": multiasset_bytes,
        "datum_type": datum_type,
        "has_reference_script": 3 in fields,
        "datum_contribution_bytes": contributions.get(2, 0),
        "reference_script_contribution_bytes": contributions.get(3, 0),
        "address_bytes": len(address.value),
        "address_contribution_bytes": contributions[0],
        "address_type": address_type,
        "address_header_type": address_tag,
        "output_encoding": encoding,
        "output_framing_bytes": output.size - sum(contributions.values()),
        "offset": output.start,
        "end_offset": output.end,
    }


def extract_chunk(path):
    path = Path(path)
    data = path.read_bytes()
    reader = Reader(data)
    rows = []
    counts = {"blocks": 0, "transactions": 0, "transaction_body_bytes": 0,
              "body_size_xor_checksum": 0, "body_hash_xor_checksum": 0,
              "invalid_transactions": 0,
              "ordinary_outputs_skipped_in_invalid_transactions": 0,
              "collateral_return_outputs": 0}
    slots, block_numbers = [], []
    while reader.pos < len(data):
        block = reader.read()
        outer = sequence(block, "hard-fork block")
        require(len(outer) == 2, "hard-fork block must be a pair")
        require(integer(outer[0], "era") == 7, "only Conway era tag 7 is supported")
        parts = sequence(outer[1], "Conway block")
        require(len(parts) == 5, "Conway block must have five components")
        header = sequence(parts[0], "header")
        require(len(header) == 2, "header must be a pair")
        header_body = sequence(header[0], "header body")
        require(len(header_body) == 10, "unexpected Conway header body length")
        block_number = integer(header_body[0], "block number")
        slot = integer(header_body[1], "slot")
        slots.append(slot)
        block_numbers.append(block_number)
        bodies = sequence(parts[1], "transaction bodies")
        invalid_node = parts[4]
        if invalid_node.major == 6:
            require(invalid_node.value[0] == 258, "unsupported invalid-index set tag")
            invalid_node = invalid_node.value[1]
        invalid_list = [integer(x, "invalid transaction index")
                        for x in sequence(invalid_node, "invalid transactions")]
        invalid = set(invalid_list)
        require(len(invalid) == len(invalid_list), "duplicate invalid transaction index")
        require(all(i < len(bodies) for i in invalid), "invalid transaction index out of range")
        counts["invalid_transactions"] += len(invalid)
        for transaction_index, body in enumerate(bodies):
            fields, _ = integer_map(body, "transaction body")
            require(1 in fields, "transaction body missing outputs")
            ordinary = sequence(fields[1], "transaction outputs")
            digest = hashlib.blake2b(data[body.start:body.end], digest_size=32).digest()
            txid = digest.hex()
            counts["transaction_body_bytes"] += body.size
            counts["body_size_xor_checksum"] ^= body.size
            # Matches the independent Haskell ScanBench.hs checksum, including
            # Word64 overflow, to cross-check original transaction-body spans.
            digest_checksum = 0
            for byte in digest:
                digest_checksum = (digest_checksum * 131 + byte) & (2**64 - 1)
            counts["body_hash_xor_checksum"] ^= digest_checksum
            is_invalid = transaction_index in invalid
            if is_invalid:
                counts["ordinary_outputs_skipped_in_invalid_transactions"] += len(ordinary)
                outputs = [(len(ordinary), fields[16])] if 16 in fields else []
                counts["collateral_return_outputs"] += len(outputs)
            else:
                outputs = enumerate(ordinary)
            for output_index, output in outputs:
                row = describe_output(output)
                row.update({"chunk": path.name, "block_number": block_number,
                            "slot": slot, "transaction_index": transaction_index,
                            "txid": txid, "output_index": output_index,
                            "is_collateral_return": is_invalid})
                rows.append(row)
        counts["blocks"] += 1
        counts["transactions"] += len(bodies)
    require(reader.pos == len(data), "chunk was not fully consumed")
    metadata = {
        "path": str(path), "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "era": "Conway", "era_tag": 7,
        **counts, "created_outputs": len(rows),
        "first_slot": min(slots) if slots else None,
        "last_slot": max(slots) if slots else None,
        "first_block": min(block_numbers) if block_numbers else None,
        "last_block": max(block_numbers) if block_numbers else None,
        "fully_consumed": True,
        "scope": "Structural extraction of outputs created by block validity flags; not ledger validation or an unspent-output census.",
    }
    return metadata, rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chunks", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New output JSONL file")
    parser.add_argument("--metadata", required=True, type=Path, help="New provenance JSON file")
    args = parser.parse_args()
    if args.output.exists() or args.metadata.exists():
        parser.error("output files must not already exist")
    metadata = []
    with args.output.open("x") as handle:
        for chunk in args.chunks:
            info, rows = extract_chunk(chunk)
            metadata.append(info)
            for row in rows:
                handle.write(json.dumps(row, separators=(",", ":")) + "\n")
    args.metadata.write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
