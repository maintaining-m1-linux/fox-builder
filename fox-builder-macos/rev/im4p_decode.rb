#!/usr/bin/ruby
# im4p_decode.rb — extract & decode the IM4P "krnl" payload from a kernelcache
# using libcompression via Fiddle. No sudo, no writes outside the workdir.
require 'fiddle'
require 'fiddle/import'

KC = ARGV[0]
OUT = ARGV[1] || 'kernelcache.macho'

data = File.binread(KC)
puts "file size: #{data.bytesize}"

# locate the compression fourcc ("bvx1"/"bvx2"/"bvx-"/"bvx9")
bvx = nil
%w[bvx2 bvx1 bvx- bvx9].each do |m|
  if (i = data.index(m))
    puts "found magic #{m} at file offset #{i} (0x#{i.to_s(16)})"
    bvx = i
    break
  end
end
abort 'no bvx magic found' unless bvx

payload = data[bvx..-1]
puts "payload bytes (magic..EOF): #{payload.bytesize}"

lib = Fiddle.dlopen('/usr/lib/libcompression.dylib')
decode = Fiddle::Function.new(lib['compression_decode_buffer'],
  [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
  Fiddle::TYPE_SIZE_T)
begin
  scratch_size_fn = Fiddle::Function.new(lib['compression_decode_scratch_buf_size'],
    [Fiddle::TYPE_INT], Fiddle::TYPE_SIZE_T)
rescue Fiddle::DLError
  scratch_size_fn = nil
end

ALGOS = { 'LZ4'=>0x0102, 'LZFSE'=>0x0801, 'ZLIB'=>0x0205, 'LZMA'=>0x0306, 'BROTLI'=>0x0B02, 'LZ4RAW'=>0x0101, 'LZBITMAP'=>0x0A05 }

ALGOS.each do |name, algo|
  dst_cap = [payload.bytesize * 12, 256*1024*1024].max
  dst = Fiddle::Pointer.malloc(dst_cap)
  src = Fiddle::Pointer[payload]
  scratch = nil
  if scratch_size_fn
    ss = scratch_size_fn.call(algo)
    scratch = Fiddle::Pointer.malloc(ss) if ss > 0
  end
  n = decode.call(dst, dst_cap, src, payload.bytesize, scratch, algo)
  ok_magic = dst[0,4] == [0xcf,0xfa,0xed,0xfe].pack('C*')
  printf "%-8s algo=0x%04x -> decoded %d bytes, mach-o magic: %s\n", name, algo, n, ok_magic
  if ok_magic && n > 0x1000
    # verify a full inner mach header before committing
    ncmds = dst[16,4].unpack1('L')
    if ncmds < 100000
      File.binwrite(OUT, dst[0,n])
      puts "WROTE #{OUT} (#{n} bytes) via #{name}"
      exit 0
    end
  end
end
abort 'all algorithms failed to yield a mach-o'
