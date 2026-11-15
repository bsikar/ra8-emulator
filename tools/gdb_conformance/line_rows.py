"""Fixture-only DWARF4 line oracle, independent of the emulator line reader."""
import struct


def section(path, wanted):
    data = path.read_bytes()
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    headers = [struct.unpack_from("<IIIIIIIIII", data, header[6] + i * header[11])
               for i in range(header[12])]
    names_header = headers[header[13]]
    names = data[names_header[4]:names_header[4] + names_header[5]]
    for found in headers:
        end = names.index(b"\0", found[0])
        if names[found[0]:end].decode() == wanted:
            return data[found[4]:found[4] + found[5]]
    raise ValueError("missing section " + wanted)


class Cursor:
    def __init__(self, data, at=0):
        self.data, self.at = data, at

    def byte(self):
        value = self.data[self.at]
        self.at += 1
        return value

    def uint(self, size):
        value = int.from_bytes(self.data[self.at:self.at + size], "little")
        self.at += size
        return value

    def leb(self, signed=False):
        value = shift = 0
        while True:
            byte = self.byte()
            value |= (byte & 127) << shift
            shift += 7
            if byte < 128:
                return value - (1 << shift) if signed and byte & 64 else value

    def string(self):
        end = self.data.index(b"\0", self.at)
        value = self.data[self.at:end].decode()
        self.at = end + 1
        return value


def rows(path):
    data = section(path, ".debug_line")
    cursor = Cursor(data)
    while cursor.at < len(data):
        length = cursor.uint(4)
        end = cursor.at + length
        if cursor.uint(2) != 4:
            raise ValueError("fixture line table must be DWARF4")
        prologue_length = cursor.uint(4)
        program = cursor.at + prologue_length
        minimum, maximum = cursor.byte(), cursor.byte()
        if maximum != 1:
            raise ValueError("fixture must use one operation per instruction")
        cursor.byte()  # default_is_stmt
        base = cursor.byte()
        if base >= 128:
            base -= 256
        span, opcode_base = cursor.byte(), cursor.byte()
        lengths = [cursor.byte() for _ in range(opcode_base - 1)]
        while cursor.string():
            pass
        files = [""]
        while True:
            name = cursor.string()
            if not name:
                break
            files.append(name.replace("\\", "/"))
            for _ in range(3):
                cursor.leb()
        cursor.at = program
        address, line, file = 0, 1, 1
        while cursor.at < end:
            opcode = cursor.byte()
            emit = False
            if opcode >= opcode_base:
                adjusted = opcode - opcode_base
                address += adjusted // span * minimum
                line += base + adjusted % span
                emit = True
            elif opcode == 0:
                size = cursor.leb()
                after = cursor.at + size
                extended = cursor.byte()
                if extended == 1:
                    address, line, file = 0, 1, 1
                elif extended == 2:
                    address = cursor.uint(size - 1)
                cursor.at = after
            elif opcode == 1:
                emit = True
            elif opcode == 2:
                address += cursor.leb() * minimum
            elif opcode == 3:
                line += cursor.leb(True)
            elif opcode == 4:
                file = cursor.leb()
            elif opcode == 8:
                address += (255 - opcode_base) // span * minimum
            elif opcode == 9:
                address += cursor.uint(2)
            else:
                for _ in range(lengths[opcode - 1]):
                    cursor.leb()
            if emit:
                yield {"file": files[file], "line": line, "address": address}
        cursor.at = end


def address_of(path, source, line):
    found = [row["address"] for row in rows(path)
             if row["file"].split("/")[-1] == source.name and row["line"] == line]
    if not found:
        raise ValueError("fixture source marker has no line-table row")
    return min(found)
