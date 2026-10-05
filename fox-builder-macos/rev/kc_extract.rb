#!/usr/bin/ruby
# kc_extract.rb — parse a KernelCollection (Mach-O w/ LC_FILESET_ENTRY) and
# extract fileset entries. Read-only w.r.t. the system; writes copies to CWD.
# Usage:
#   ruby kc_extract.rb <kc-file> list
#   ruby kc_extract.rb <kc-file> extract <regex> <outdir>
require 'fileutils'

KC, MODE = ARGV[0], ARGV[1]
data = File.binread(KC)

raise "not mach-o" unless data[0,4].unpack1('L') == 0xfeedfacf
ncmds, sizeofcmds = data[16,8].unpack('LL')
puts "ncmds=#{ncmds} sizeofcmds=#{sizeofcmds}"

LC_FILESET_ENTRY = 0x80000035
off = 32
entries = []
ncmds.times do
  cmd, cmdsize = data[off, 8].unpack('LL')
  if cmd == LC_FILESET_ENTRY
    vmaddr, vmsize, fileoff = data[off+8, 24].unpack('QQQ')
    idlen = cmdsize - 8 - 24
    entry_id = data[off+32, idlen].unpack1('Z*')
    entries << { name: entry_id, vmaddr: vmaddr, vmsize: vmsize, fileoff: fileoff }
  end
  off += cmdsize
end

case MODE
when 'list'
  entries.each { |e| printf "%-60s vmaddr=0x%016x fileoff=0x%08x vmsize=0x%08x\n", e[:name], e[:vmaddr], e[:fileoff], e[:vmsize] }
when 'extract'
  re = Regexp.new(ARGV[2])
  outdir = ARGV[3] || '.'
  FileUtils.mkdir_p(outdir)
  # collect main-header LC_SEGMENT_64 (cmd 0x19): vmaddr, vmsize, fileoff, filesize, segname
  segs = []
  ncmds, = data[16, 8].unpack('L')
  so = 32
  ncmds.times do
    cmd, cmdsize = data[so, 8].unpack('LL')
    if cmd == 0x19
      segname = data[so+8, 16].unpack1('Z*')
      vmaddr, vmsize, fileoff, filesize = data[so+24, 32].unpack('QQQQ')
      segs << { name: segname, vmaddr: vmaddr, vmsize: vmsize, fileoff: fileoff, filesize: filesize }
    end
    so += cmdsize
  end
  entries.select { |e| e[:name] =~ re }.each do |e|
    seg = segs.find { |s| s[:vmaddr] <= e[:vmaddr] && e[:vmaddr] < s[:vmaddr] + s[:vmsize] }
    raise "no segment covers #{e[:name]} vmaddr=#{e[:vmaddr].to_s(16)}" unless seg
    fo = seg[:fileoff] + (e[:vmaddr] - seg[:vmaddr])
    inner = data[fo, 0x4000] # kext mach header + load commands sit at its __TEXT start
    raise "bad inner magic for #{e[:name]} at fileoff #{fo}" unless inner[0,4].unpack1('L') == 0xfeedfacf
    in_ncmds, = inner[16, 8].unpack('L')
    ksegs = []
    symtab = nil
    io = 32
    in_ncmds.times do
      icmd, ics = inner[io,8].unpack('LL')
      if icmd == 0x19
        segname = inner[io+8,16].unpack1('Z*')
        vmaddr, vmsize, fileoff, filesize = inner[io+24,32].unpack('QQQQ')
        ksegs << { name: segname, vmaddr: vmaddr, vmsize: vmsize, fileoff: fileoff, filesize: filesize }
      elsif icmd == 0x2 # LC_SYMTAB
        symoff, nsyms, stroff, strsize = inner[io+8,16].unpack('LLLL')
        symtab = { symoff: symoff, nsyms: nsyms, stroff: stroff, strsize: strsize }
      end
      io += ics
    end
    short = e[:name].split('.').last
    # vmaddr-contiguous image: pointers/relocations already resolved to final VAs
    base = ksegs.map { |s| s[:vmaddr] }.min
    top  = ksegs.map { |s| s[:vmaddr] + s[:vmsize] }.max
    img = "\0" * (top - base)
    ksegs.each do |s|
      img[s[:vmaddr]-base, s[:filesize]] = data[s[:fileoff], s[:filesize]]
    end
    File.binwrite(File.join(outdir, short + '.image'), img)
    File.open(File.join(outdir, short + '.map.txt'), 'w') do |m|
      m.puts "kext=#{e[:name]} base_vmaddr=0x#{base.to_s(16)} image_size=0x#{(top-base).to_s(16)}"
      ksegs.each { |s| m.puts format("seg %-16s vmaddr=%016x vmsize=%#010x fileoff=%#010x filesize=%#010x img_off=%#010x", s[:name], s[:vmaddr], s[:vmsize], s[:fileoff], s[:filesize], s[:vmaddr]-base) }
      m.puts "symtab #{symtab.inspect}" if symtab
    end
    printf "extracted %-50s base=%016x size=%#08x (%d segs)\n", e[:name], base, top-base, ksegs.size
  end
else
  abort "unknown mode #{MODE}"
end
