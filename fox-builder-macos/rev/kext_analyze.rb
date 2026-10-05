#!/usr/bin/ruby
# kext_analyze.rb — per-kext symbols (from KC LC_SYMTAB) + local strings
# (from __cstring/__os_log/__const sections listed in <kext>.map.txt).
# Usage: ruby kext_analyze.rb <kernelcache.macho> <kextdir>
kc_path, dir = ARGV[0], ARGV[1]
kc = File.binread(kc_path)
map = File.read(File.join(dir, File.basename(dir) + '.map.txt'))

kext = map[/^kext=(\S+)/, 1]
text_fo = map[/text_header_fileoff=(0x[0-9a-f]+)/, 1].to_i(16)
sects = []
map.scan(/^  sect (\S+)\s+vmaddr=(0x[0-9a-f]+) size=(0x[0-9a-f]+) kc_fileoff=(0x[0-9a-f]+)/) do |n, v, s, f|
  sects << { name: n, vmaddr: v.to_i(16), size: s.to_i(16), fileoff: f.to_i(16) }
end
seg_range = map.scan(/^seg \S+\s+vmaddr=(0x[0-9a-f]+) filesize=(0x[0-9a-f]+)/).map { |v, s| [v.to_i(16), s.to_i(16)] }
lo = seg_range.map(&:first).min
hi = seg_range.map { |v, s| v + s }.max

# symtab from the kext's own inner header
inner = kc[text_fo, 0x8000]
ncmds = inner[16, 4].unpack1('L')
symtab = nil
io = 32
ncmds.times do
  cmd, cs = inner[io, 8].unpack('LL')
  if cmd == 0x2
    symoff, nsyms, stroff, strsize = inner[io+8, 16].unpack('LLLL')
    symtab = { symoff: symoff, nsyms: nsyms, stroff: stroff }
  end
  io += cs
end

out = File.join(dir, File.basename(dir))
if symtab
  syms = []
  symtab[:nsyms].times do |i|
    e = kc[symtab[:symoff] + i*16, 16]
    break if e.nil? || e.bytesize < 16
    strx, type, sect, desc, value = e.unpack('LCCSQQ')
    next if (type & 0x0e) == 0
    next unless value >= lo && value < hi
    name = kc[symtab[:stroff] + strx, 300].unpack1('Z*') rescue ''
    syms << [value, name]
  end
  syms = syms.uniq.sort_by(&:first)
  File.open(out + '.symbols.txt', 'w') { |f| syms.each { |v, n| f.puts format('%016x %s', v, n) } }
  puts "#{File.basename(dir)}: #{syms.size} symbols"
else
  puts "#{File.basename(dir)}: no symtab"
end

File.open(out + '.strings.txt', 'w') do |f|
  sects.select { |s| %w[__cstring __os_log].include?(s[:name]) }.each do |s|
    buf = kc[s[:fileoff], s[:size]]
    cur = +''
    buf.each_byte do |b|
      if b >= 0x20 && b < 0x7f then cur << b
      else
        f.puts cur if cur.bytesize >= 5
        cur = +''
      end
    end
    f.puts cur if cur.bytesize >= 5
  end
end
puts "#{File.basename(dir)}: strings done"
