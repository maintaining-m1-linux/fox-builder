#!/usr/bin/ruby
# avd_sym_strings.rb — nm/strings stand-ins for the extracted AppleAVD image.
# Parses LC_SYMTAB (nlist_64) out of the kernelcache file and scans image
# regions for printable strings and AVD-related 64-bit constants.
require 'json'

REV = File.dirname(__FILE__)
IMG = File.join(REV, 'extracted/AppleAVD.image')
MAP = File.join(REV, 'extracted/AppleAVD.map.txt')
KC  = File.join(REV, 'kernelcache.macho')

map = { segs: [] }
File.foreach(MAP) do |l|
  if l =~ /^seg (\S+)\s+vmaddr=([0-9a-f]+) vmsize=(0x[0-9a-f]+) fileoff=(0x[0-9a-f]+) filesize=(0x[0-9a-f]+) img_off=(0x[0-9a-f]+)/
    map[:segs] << { name: $1, vmaddr: $2.to_i(16), vmsize: $3.to_i(16), fileoff: $4.to_i(16), filesize: $5.to_i(16), img_off: $6.to_i(16) }
  elsif l =~ /^kext=(\S+) base_vmaddr=(0x[0-9a-f]+) image_size=(0x[0-9a-f]+)/
    map[:kext] = $1; map[:base] = $2.to_i(16); map[:size] = $3.to_i(16)
  elsif l =~ /^symtab \{:symoff=>(\d+), :nsyms=>(\d+), :stroff=>(\d+), :strsize=>(\d+)\}/
    map[:sym] = { symoff: $1.to_i, nsyms: $2.to_i, stroff: $3.to_i, strsize: $4.to_i }
  end
end

img = File.binread(IMG)
kc  = File.binread(KC)

# ---------- symbols ----------
syms = []
ns = map[:sym][:nsyms]
ns.times do |i|
  e = kc[map[:sym][:symoff] + i*16, 16]
  break if e.nil? || e.bytesize < 16
  strx, type, sect, desc, value = e.unpack('LCCSQQ')
  name = kc[map[:sym][:stroff] + strx, 256].unpack1('Z*') rescue ''
  syms << { name: name, type: type, sect: sect, value: value }
end
# keep defined symbols within this kext's vm range
lo, hi = map[:base], map[:base] + map[:size]
own = syms.select { |s| (s[:type] & 0x0e) != 0 && s[:value] >= lo && s[:value] < hi }
          .sort_by { |s| s[:value] }
# dedupe by value+name
seen = {}; own = own.reject { |s| seen[[s[:value],s[:name]]] ? true : (seen[[s[:value],s[:name]]] = true; false) }

File.open(File.join(REV, 'avd_symbols.txt'), 'w') do |f|
  own.each { |s| f.puts format("%016x %s", s[:value], s[:name]) }
end
puts "symbols total=#{ns} in-kext=#{own.size} -> avd_symbols.txt"

# ---------- strings over __TEXT/__DATA/__TEXT_EXEC ----------
def strings_in(img, from, len, min: 5)
  out = []
  cur = +''
  img[from, len].each_byte do |b|
    if b >= 0x20 && b < 0x7f
      cur << b
    else
      out << cur if cur.bytesize >= min
      cur = +''
    end
  end
  out << cur if cur.bytesize >= min
  out
end

str_report = {}
%w[__TEXT __TEXT_EXEC __DATA __DATA_CONST].each do |sn|
  sg = map[:segs].find { |s| s[:name] == sn }
  next unless sg
  str_report[sn] = strings_in(img, sg[:img_off], sg[:filesize], min: 6)
end
File.open(File.join(REV, 'avd_strings.txt'), 'w') do |f|
  str_report.each do |sn, arr|
    arr.each { |s| f.puts "#{sn}: #{s}" }
  end
end
puts "strings -> avd_strings.txt (#{str_report.values.sum(&:size)})"

# interesting strings
kw = /avd|avf|fw|firm|clock|power|reset|enable|boot|load|timeout|2690|ctrl|mbox|sram|dart|rtk|error|fail|hevc|h264|vt\./i
File.open(File.join(REV, 'avd_strings_interesting.txt'), 'w') do |f|
  str_report.each do |sn, arr|
    arr.each { |s| f.puts "#{sn}: #{s}" if s =~ kw }
  end
end
puts "interesting strings -> avd_strings_interesting.txt"

# ---------- 64-bit constant scan for AVD physical addresses ----------
# known Linux-map regions (from MACOS_REVERSE.md / apple-avd driver):
ranges = [
  [0x269000000, 0x26a000000, 'AVD global (mbox 0x269098000, ctrl 0x269100000)'],
  [0x269080000, 0x269100000, 'AVD mbox region'],
  [0x269100000, 0x269200000, 'AVD ctrl region'],
  [0x400000000, 0x500000000, 'CM3 firmware decode-ctrl base region'],
]
hits = []
step = 8
[ '__TEXT_EXEC', '__DATA_CONST', '__DATA', '__TEXT' ].each do |sn|
  sg = map[:segs].find { |s| s[:name] == sn }
  next unless sg
  base_io = sg[:img_off]
  buf = img[base_io, sg[:filesize]]
  (buf.bytesize / 8).times do |i|
    v = buf[i*8, 8].unpack1('Q')
    ranges.each do |a, b, tag|
      if v >= a && v < b
        va = sg[:vmaddr] + i*8
        hits << { seg: sn, va: va, off: i*8, value: v, tag: tag }
        break
      end
    end
  end
end
File.open(File.join(REV, 'avd_phys_const_hits.txt'), 'w') do |f|
  hits.each { |h| f.puts format("%-12s va=%016x fileimg_off=%#010x value=%016x %s", h[:seg], h[:va], h[:off], h[:value], h[:tag]) }
end
puts "phys const hits=#{hits.size} -> avd_phys_const_hits.txt"

# ---------- IM4P / firmware blob scan ----------
fw = []
idx = 0
while (j = img.index('IM4P', idx))
  fw << j; idx = j + 4
end
idx = 0
bvx = []
while (j = img.index('bvx', idx))
  bvx << j; idx = j + 3
end
puts "IM4P magic at img offsets: #{fw.map { |x| '0x'+x.to_s(16) }.inspect}"
puts "bvx  magic at img offsets: #{bvx.map { |x| '0x'+x.to_s(16) }.inspect}"
File.write(File.join(REV, 'avd_fw_scan.txt'), "IM4P: #{fw.inspect}\nbvx: #{bvx.inspect}\n")
