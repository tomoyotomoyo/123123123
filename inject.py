import struct, os, sys

def inject_dylib(binary_path, dylib_path):
    with open(binary_path, 'rb') as f:
        data = bytearray(f.read())

    magic = struct.unpack_from('<I', data, 0)[0]
    if magic != 0xFEEDFACF:
        print(f"Error: Not arm64 Mach-O (magic: {hex(magic)})")
        sys.exit(1)
    
    header_size = 32
    ncmds = struct.unpack_from('<I', data, 16)[0]
    sizeofcmds = struct.unpack_from('<I', data, 20)[0]
    
    dylib_name = dylib_path
    name_len = len(dylib_name) + 1
    load_dylib_size = 24 + name_len
    if load_dylib_size % 8 != 0:
        load_dylib_size += 8 - (load_dylib_size % 8)
    
    new_sizeofcmds = sizeofcmds + load_dylib_size
    new_ncmds = ncmds + 1
    
    # LC_LOAD_DYLIB: cmd(4) + cmdsize(4) + name_offset(4) + timestamp(4) + current_version(4) + compatibility_version(4) = 24 bytes header
    new_cmd = struct.pack('<IIIIII', 0x18, load_dylib_size, 24, 0, 0, 0)
    new_cmd += dylib_name.encode('ascii') + b'\x00'
    pad_len = load_dylib_size - len(new_cmd)
    new_cmd += b'\x00' * pad_len
    
    # Find end of existing load commands
    offset = header_size
    for i in range(ncmds):
        cmd_size = struct.unpack_from('<I', data, offset + 4)[0]
        offset += cmd_size
    
    # Insert new command
    data[offset:offset] = new_cmd
    struct.pack_into('<I', data, 16, new_ncmds)
    struct.pack_into('<I', data, 20, new_sizeofcmds)
    
    with open(binary_path, 'wb') as f:
        f.write(data)
    print(f"Success: Added LC_LOAD_DYLIB for {dylib_name}")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python3 inject.py <binary_path> <dylib_path>")
        sys.exit(1)
    inject_dylib(sys.argv[1], sys.argv[2])
