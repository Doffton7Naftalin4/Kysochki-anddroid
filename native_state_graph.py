"""Byte-preserving HD1 state-machine reader/writer for isolated research.

Schema follows native 0x140266c90/0x1402669b0 on the pinned x64 executable.
Unknown fields retain raw integers, including float bit patterns. No resource
is loaded, exported, installed or mutated globally by importing this module.
"""
from collections import Counter
import copy
from dataclasses import dataclass, field
import hashlib
import struct


class FormatError(ValueError):
    pass


class Reader:
    def __init__(self, data):
        self.data = data
        self.at = 0

    def take(self, fmt):
        size = struct.calcsize("<" + fmt)
        if self.at + size > len(self.data):
            raise FormatError(f"truncated field at {self.at}")
        value = struct.unpack_from("<" + fmt, self.data, self.at)
        self.at += size
        return value[0] if len(value) == 1 else value

    def count(self, width=1):
        count = self.take("I")
        if count > 100000 or count * width > len(self.data) - self.at:
            raise FormatError(f"invalid count {count} at {self.at - 4}")
        return count

    def array(self, fmt):
        return [self.take(fmt) for _ in range(self.count(struct.calcsize("<" + fmt)))]

    def blob(self):
        size = self.count()
        data = self.data[self.at:self.at + size]
        self.at += size
        return data


class Writer:
    def __init__(self):
        self.data = bytearray()

    def put(self, fmt, value):
        values = value if isinstance(value, tuple) else (value,)
        self.data += struct.pack("<" + fmt, *values)

    def array(self, fmt, values):
        self.put("I", len(values))
        for value in values:
            self.put(fmt, value)

    def blob(self, data):
        self.put("I", len(data))
        self.data += data


@dataclass
class State:
    name: int
    kind: int
    animations: list
    header_words: list
    end_event: int
    loop: int
    end_time_word: int
    links: list
    signal_records: list
    parameter_pair: tuple
    expression_words: list
    expression_offsets: list
    control_words: tuple
    constraints: list
    final_words: tuple
    offset: int = 0
    constraints_offset: int = 0

    @classmethod
    def read(cls, reader):
        start = reader.at
        name, kind = reader.take("Q"), reader.take("I")
        animations, header = reader.array("Q"), reader.array("I")
        end_event, loop, end_time = reader.take("I"), reader.take("B"), reader.take("I")
        if kind > 5 or loop > 1:
            raise FormatError(f"unsupported state kind/loop at {start}")
        links, signals = reader.array("5I"), reader.array("3I")
        pair = reader.take("2I")
        expressions, offsets = reader.array("I"), reader.array("I")
        controls = reader.take("3I")
        constraints_offset = reader.at
        constraints, final = reader.array("I"), reader.take("3I")
        return cls(name, kind, animations, header, end_event, loop, end_time,
                   links, signals, pair, expressions, offsets, controls,
                   constraints, final, start, constraints_offset)

    def write(self, writer):
        writer.put("Q", self.name)
        writer.put("I", self.kind)
        writer.array("Q", self.animations)
        writer.array("I", self.header_words)
        writer.put("I", self.end_event)
        writer.put("B", self.loop)
        writer.put("I", self.end_time_word)
        writer.array("5I", self.links)
        writer.array("3I", self.signal_records)
        writer.put("2I", self.parameter_pair)
        writer.array("I", self.expression_words)
        writer.array("I", self.expression_offsets)
        writer.put("3I", self.control_words)
        writer.array("I", self.constraints)
        writer.put("3I", self.final_words)


@dataclass
class Layer:
    states: list
    default: int


@dataclass
class Graph:
    layers: list
    event_hashes: list
    variable_hashes: list
    default_variable_words: list
    mask_words: list
    target_hashes: list
    target_position_words: list
    constraint_program: bytes
    extra_pairs: list
    field_offsets: dict = field(default_factory=dict)

    @classmethod
    def parse(cls, data):
        reader = Reader(data)
        layers = []
        for _ in range(reader.count(4)):
            states = [State.read(reader) for _ in range(reader.count(16))]
            default = reader.take("I")
            if not states or default >= len(states):
                raise FormatError("invalid layer default")
            layers.append(Layer(states, default))
        offsets = {"events": reader.at}
        events = reader.array("I")
        offsets["variables"] = reader.at
        variables, defaults = reader.array("I"), reader.array("I")
        if len(variables) != len(defaults):
            raise FormatError("variable/default count mismatch")
        offsets["masks"] = reader.at
        masks = [reader.array("I") for _ in range(reader.count(4))]
        offsets["target_hashes"] = reader.at
        targets, positions = reader.array("I"), reader.array("3I")
        if len(targets) != len(positions):
            raise FormatError("target/default count mismatch")
        offsets["constraint_program"] = reader.at
        program = reader.blob()
        offsets["extra_pairs"] = reader.at
        extras = [(reader.array("I"), reader.array("I")) for _ in range(reader.count(8))]
        if reader.at != len(data):
            raise FormatError(f"unconsumed bytes at {reader.at}")
        return cls(layers, events, variables, defaults, masks, targets,
                   positions, program, extras, offsets)

    def to_bytes(self):
        writer = Writer()
        writer.put("I", len(self.layers))
        for layer in self.layers:
            writer.put("I", len(layer.states))
            for state in layer.states:
                state.write(writer)
            writer.put("I", layer.default)
        writer.array("I", self.event_hashes)
        writer.array("I", self.variable_hashes)
        writer.array("I", self.default_variable_words)
        writer.put("I", len(self.mask_words))
        for mask in self.mask_words:
            writer.array("I", mask)
        writer.array("I", self.target_hashes)
        writer.array("3I", self.target_position_words)
        writer.blob(self.constraint_program)
        writer.put("I", len(self.extra_pairs))
        for first, second in self.extra_pairs:
            writer.array("I", first)
            writer.array("I", second)
        return bytes(writer.data)

    def manifest(self):
        activations = []
        filters = []
        for number, layer in enumerate(self.layers):
            filters.append(dict(Counter(state.control_words[2] for state in layer.states)))
            for index, state in enumerate(layer.states):
                if state.constraints:
                    activations.append({"layer": number, "state": index, "constraints": list(state.constraints)})
        words = list(struct.unpack("<" + "I" * (len(self.constraint_program) // 4), self.constraint_program))
        return {
            "layer_state_counts": [len(layer.states) for layer in self.layers],
            "layer_bone_filter_counts": filters,
            "constraint_activations": activations,
            "target_hashes": list(self.target_hashes),
            "constraint_program_words": words,
            "mask_nonzero": [[i for i, word in enumerate(mask) if struct.unpack("<f", struct.pack("<I", word))[0] != 0] for mask in self.mask_words],
            "safe_candidate_ready": False,
            "remaining_contracts": ["safe state/layer selection", "final blend/constraint order", "runtime disable/no-op", "hand/muzzle alignment and native validation"],
        }


def hash64(text):
    """The original resource/name hash; graph event/target IDs use its high32."""
    data = text.encode("utf-8")
    mask, multiplier = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * multiplier & mask
    for offset in range(0, len(data) // 8 * 8, 8):
        word, = struct.unpack_from("<Q", data, offset)
        word = word * multiplier & mask
        word ^= word >> 47
        word = word * multiplier & mask
        value = (value ^ word) * multiplier & mask
    tail = data[len(data) // 8 * 8:]
    for index, byte in enumerate(tail):
        value ^= byte << (index * 8)
    if tail:
        value = value * multiplier & mask
    value ^= value >> 47
    value = value * multiplier & mask
    return value ^ (value >> 47)


@dataclass
class PoseTwins:
    graph: Graph
    base_counts: tuple
    on_hash: int
    off_hash: int

    def canonical_states(self, states):
        """Research equivalent of the required outbound RPC boundary mapping."""
        if not isinstance(states, (tuple, list)) or len(states) != len(self.base_counts):
            raise FormatError("animation state tuple must contain exactly nine layers")
        result = []
        for value, count in zip(states, self.base_counts):
            if value is None:
                result.append(None)
            elif type(value) is not int or not 0 <= value < 2 * count:
                raise FormatError("invalid animation state index")
            else:
                result.append(value % count)
        return result


def build_pose_twins(source):
    """Build an unexported review object, never a claimed runtime-safe graph.

    Original definitions/IDs/defaults stay intact. New states carry native
    constraints only when their original clip filter includes spine2. Native
    event transitions stay in the chosen half; private on/off use the engine's
    existing type4 normalized-phase transition. No file or engine API is called.
    """
    counts = (69, 93, 191, 5, 98, 23, 5, 20, 4)
    if tuple(len(layer.states) for layer in source.layers) != counts:
        raise FormatError("unexpected source layers/states")
    if len(source.mask_words) != 6 or any(len(mask) != 83 for mask in source.mask_words):
        raise FormatError("unexpected source mask layout")
    if source.target_hashes != [0x1ED3F014] or source.target_position_words != [(0, 0, 0)]:
        raise FormatError("unexpected source target definition")
    expected_program = struct.pack("<6I", 1, 8, 1, 0, 0, 37)
    if source.constraint_program != expected_program:
        raise FormatError("unexpected source constraint definition")
    if any(state.constraints for layer in source.layers for state in layer.states):
        raise FormatError("source already enables constraints")
    for count, layer in zip(counts, source.layers):
        for state in layer.states:
            index = state.control_words[2]
            if index != 0xFFFFFFFF and index >= len(source.mask_words):
                raise FormatError("invalid source layer filter")
            if any(link[1] >= count for link in state.links):
                raise FormatError("invalid source transition target")
    if hashlib.sha256(source.to_bytes()).hexdigest() != "46e1a4590c324a47eda0180f66c75f77ac1cada09eeee68ccf78d6ac2cfb40b4":
        raise FormatError("source does not match the pinned original graph")
    on_hash, off_hash = (hash64(name) >> 32 for name in ("hd_pose_on", "hd_pose_off"))
    target_hash = hash64("hd_camera_aim") >> 32
    if on_hash == off_hash or on_hash in source.event_hashes or off_hash in source.event_hashes:
        raise FormatError("private event hash collision")
    if target_hash in source.target_hashes:
        raise FormatError("private target hash collision")
    graph = copy.deepcopy(source)
    for number, (count, source_layer, layer) in enumerate(zip(counts, source.layers, graph.layers)):
        twins = []
        for index, state in enumerate(source_layer.states):
            twin = copy.deepcopy(state)
            twin.name = hash64(f"hd_camera_pose/{number}/{index}")
            if any(twin.name == existing.name for existing in source_layer.states + twins):
                raise FormatError("private state hash collision")
            twin.links = [(event, target + count, blend, kind, beat)
                          for event, target, blend, kind, beat in state.links]
            twin.links.append((off_hash, index, 0, 4, 0))
            filter_index = state.control_words[2]
            includes_spine = filter_index == 0xFFFFFFFF or source.mask_words[filter_index][8] != 0
            twin.constraints = [1] if state.animations and state.kind != 1 and includes_spine else []
            twins.append(twin)
            layer.states[index].links.append((on_hash, index + count, 0, 4, 0))
        layer.states.extend(twins)
    mask = [0] * 83
    mask[8] = 0x3F800000
    graph.mask_words.append(mask)
    graph.target_hashes.append(target_hash)
    graph.target_position_words.append((0, 0, 0))
    # The added torso constraint uses the foregrip point. The original head
    # constraint retains aim37; its point is far above the torso and does not
    # represent the barrel direction when reused with the spine2 pivot.
    graph.constraint_program = struct.pack("<11I", 2, 12, 28, 1, 0, 0, 37, 1, 6, 1, 54)
    graph.event_hashes = sorted(source.event_hashes + [on_hash, off_hash])
    # Re-read to refresh all offsets and reject an inconsistent serialization.
    graph = Graph.parse(graph.to_bytes())
    return PoseTwins(graph, counts, on_hash, off_hash)
