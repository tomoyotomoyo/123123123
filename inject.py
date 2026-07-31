import struct
import sys

def read_macho64_header(data):
    """Parse Mach-O 64 header, returns dict with all fields"""
    if len(data) < 112:
        return None
    
    magic = struct.unpack_from('<I', data, 0)[0]
    if magic != 0xFEEDFACF:
        return None
    
    return {
        'magic': magic,
        'cputype': struct.unpack_from('<I', data, 4)[0],
        'cpusubtype': struct.unpack_from('<I', data, 8)[0],
        'filetype': struct.unpack_from('<I', data, 12)[0],
        'ncmds': struct.unpack_from('<I', data, 16)[0],
        'sizeofcmds': struct.unpack_from('<I', data, 20)[0],
        'flags': struct.unpack_from('<I', data, 24)[0],
        'reserved': struct.unpack_from('<I', data, 28)[0],
        'seg_offset': struct.unpack_from('<Q', data, 32)[0],
        'seg_size': struct.unpack_from('<Q', data, 40)[0],
        'lc_offset': struct.unpack_from('<Q', data, 48)[0],
        'lc_size': struct.unpack_from('<Q', data, 56)[0],
        'symtab_offset': struct.unpack_from('<Q', data, 64)[0],
        'symtab_size': struct.unpack_from('<Q', data, 72)[0],
        'dyld_hint_offset': struct.unpack_from('<Q', data, 80)[0],
        'dyld_hint_size': struct.unpack_from('<Q', data, 88)[0],
        'uuid': data[96:112]
    }

def parse_load_commands(data, lc_offset, ncmds):
    """Parse all load commands, returns list of dicts"""
    commands = []
    offset = lc_offset
    
    for i in range(ncmds):
        if offset + 8 > len(data):
            break
        
        cmd = struct.unpack_from('<I', data, offset)[0]
        cmdsize = struct.unpack_from('<I', data, offset + 4)[0]
        
        if cmdsize == 0:
            break
        
        cmd_info = {
            'cmd': cmd,
            'cmdsize': cmdsize,
            'offset': offset
        }
        
        # Parse LC_SEGMENT_64
        if cmd == 0x19:  # LC_SEGMENT_64
            if offset + 72 <= len(data):
                cmd_info['segname'] = data[offset+8:offset+24].rstrip(b'\x00').decode('ascii', errors='replace')
                cmd_info['vmaddr'] = struct.unpack_from('<Q', data, offset + 24)[0]
                cmd_info['vmsize'] = struct.unpack_from('<Q', data, offset + 32)[0]
                cmd_info['fileoff'] = struct.unpack_from('<Q', data, offset + 40)[0]
                cmd_info['filesize'] = struct.unpack_from('<Q', data, offset + 48)[0]
                cmd_info['maxprot'] = struct.unpack_from('<I', data, offset + 56)[0]
                cmd_info['initprot'] = struct.unpack_from('<I', data, offset + 60)[0]
                cmd_info['nsects'] = struct.unpack_from('<I', data, offset + 64)[0]
                cmd_info['flags'] = struct.unpack_from('<I', data, offset + 68)[0]
        
        commands.append(cmd_info)
        offset += cmdsize
    
    return commands

def find_padding_between_segments(data, commands, lc_offset, sizeofcmds):
    """Find padding between load commands and next segment"""
    # Find end of load commands
    lc_end = lc_offset + sizeofcmds
    
    # Find the minimum fileoff of all segments that start after load commands
    min_fileoff_after_lc = float('inf')
    
    for cmd in commands:
        if cmd['cmd'] == 0x19:  # LC_SEGMENT_64
            seg_fileoff = cmd.get('fileoff', 0)
            if seg_fileoff > lc_offset and seg_fileoff < min_fileoff_after_lc:
                min_fileoff_after_lc = seg_fileoff
    
    # Calculate available padding
    if min_fileoff_after_lc != float('inf'):
        padding = min_fileoff_after_lc - lc_end
    else:
        padding = len(data) - lc_end
    
    return max(0, padding)

def add_lc_load_dylib(binary_path, dylib_path):
    """Add LC_LOAD_DYLIB command to Mach-O 64 binary"""
    with open(binary_path, 'rb') as f:
        data = bytearray(f.read())
    
    # Parse header
    header = read_macho64_header(data)
    if header is None:
        print("Error: Not a valid Mach-O 64 binary")
        return False
    
    ncmds = header['ncmds']
    sizeofcmds = header['sizeofcmds']
    lc_offset = header['lc_offset']
    
    print(f"Binary: ncmds={ncmds}, sizeofcmds={sizeofcmds}, lc_offset={lc_offset}")
    
    # Parse existing load commands
    commands = parse_load_commands(data, lc_offset, ncmds)
    
    # Calculate actual end of used load commands
    actual_lc_end = lc_offset
    for cmd in commands:
        actual_lc_end = max(actual_lc_end, cmd['offset'] + cmd['cmdsize'])
    
    used_space = actual_lc_end - lc_offset
    print(f"Used load command space: {used_space} bytes")
    
    # Calculate needed size for new LC_LOAD_DYLIB
    name = dylib_path
    name_with_null = name.encode('ascii') + b'\x00'
    name_len = len(name_with_null)
    load_dylib_size = 24 + name_len
    if load_dylib_size % 8 != 0:
        load_dylib_size += 8 - (load_dylib_size % 8)
    
    print(f"New LC_LOAD_DYLIB size: {load_dylib_size} bytes")
    
    # Build new command
    new_cmd = struct.pack('<IIIIII', 
        0x18,              # cmd = LC_LOAD_DYLIB
        load_dylib_size,   # cmdsize
        24,                # name_offset (relative to start of this command)
        0,                 # timestamp
        0,                 # current_version
        0                  # compatibility_version
    )
    new_cmd += name_with_null
    pad_len = load_dylib_size - len(new_cmd)
    new_cmd += b'\x00' * pad_len
    
    # Find available padding
    padding = find_padding_between_segments(data, commands, lc_offset, sizeofcmds)
    print(f"Available padding: {padding} bytes")
    
    # Strategy: Use existing padding if possible
    if padding >= load_dylib_size:
        print(f"Using {load_dylib_size} bytes of existing padding")
        
        # Write new command at the end of existing load commands
        insert_at = actual_lc_end
        data[insert_at:insert_at + load_dylib_size] = new_cmd
        
        # Update header
        new_ncmds = ncmds + 1
        
        struct.pack_into('<I', data, 16, new_ncmds)
        
        with open(binary_path, 'wb') as f:
            f.write(data)
        
        print(f"Success! Added LC_LOAD_DYLIB for {dylib_path}")
        print(f"  ncmds: {ncmds} -> {new_ncmds}")
        print(f"  No file size change (used existing padding)")
        return True
    else:
        print(f"Not enough padding ({padding} < {load_dylib_size})")
        print("This binary may not have enough padding space.")
        print("Try using a different binary or reducing dylib name length.")
        return False

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python3 inject.py <binary_path> <dylib_path>")
        sys.exit(1)
    
    binary_path = sys.argv[1]
    dylib_path = sys.argv[2]
    
    success = add_lc_load_dylib(binary_path, dylib_path)
    sys.exit(0 if success else 1)
