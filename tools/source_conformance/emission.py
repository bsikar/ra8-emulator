"""Independently inspect the exact DWARF4 emission this regression requires."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gdb_conformance"))
from line_rows import Cursor, section


def line_units(elf):
    data = section(elf, ".debug_line")
    cursor, units = Cursor(data), []
    while cursor.at < len(data):
        offset = cursor.at
        length = cursor.uint(4)
        assert length != 0xffffffff, "fixture must use DWARF32 line units"
        end = cursor.at + length
        version = cursor.uint(2)
        assert version == 4, "fixture must emit DWARF4"
        program = cursor.at + 4 + cursor.uint(4)
        for _ in range(5):
            cursor.byte()
        opcode_base = cursor.byte()
        for _ in range(opcode_base - 1):
            cursor.byte()
        directories = []
        while True:
            directory = cursor.string()
            if not directory:
                break
            directories.append(directory)
        files = []
        while True:
            name = cursor.string()
            if not name:
                break
            index, modified, size = cursor.leb(), cursor.leb(), cursor.leb()
            files.append(dict(name=name, directory_index=index,
                              directory=directories[index-1] if index else ""))
        assert cursor.at == program, "independent line prologue extent"
        units.append(dict(offset=offset, version=version, directories=directories, files=files))
        cursor.at = end
    return units


def compilation(elf):
    info = Cursor(section(elf, ".debug_info"))
    info.uint(4)
    assert info.uint(2) == 4, "fixture compilation unit must emit DWARF4"
    abbreviation, address_size, code = info.uint(4), info.byte(), info.leb()
    cursor = Cursor(section(elf, ".debug_abbrev"), abbreviation)
    while True:
        number = cursor.leb()
        assert number, "root abbreviation exists"
        tag, children = cursor.leb(), cursor.byte()
        fields = []
        while True:
            attribute, form = cursor.leb(), cursor.leb()
            if not attribute and not form:
                break
            fields.append((attribute, form))
        if number == code:
            assert tag == 0x11, "root is compilation unit"
            break
    strings, result = section(elf, ".debug_str"), {}
    for attribute, form in fields:
        if form == 0x0e:
            at = info.uint(4)
            value = strings[at:strings.index(b"\0", at)].decode("utf8")
        elif form == 8:
            value = info.string()
        elif form in (1, 5, 6, 7, 11, 12, 19, 23):
            value = info.uint({1: address_size, 5: 2, 6: 4, 7: 8, 11: 1, 12: 1, 19: 4, 23: 4}[form])
        elif form in (15, 21):
            value = info.leb()
        elif form == 25:
            value = True
        else:
            raise AssertionError("unsupported root form " + hex(form))
        result[attribute] = value
    return dict(comp_dir=result[0x1b], stmt_list=result[0x10], producer=result.get(0x25))


def assert_emission(case, elf, source):
    units, unit = line_units(elf), compilation(elf)
    found = next(item for item in units if item["offset"] == unit["stmt_list"])
    entry = next(item for item in found["files"] if item["name"] == source.name)
    case.equal("actual line filename is basename", source.name, entry["name"])
    case.equal("actual line filename uses directory index zero", 0, entry["directory_index"])
    case.equal("actual CU comp_dir is fresh project", source.parent.resolve(), Path(unit["comp_dir"]).resolve())
    case.record("independent_dwarf_emission", compilation=unit, file=entry, line_unit_offset=found["offset"])
