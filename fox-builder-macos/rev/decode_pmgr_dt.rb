#!/usr/bin/ruby
# decode_pmgr_dt.rb — decode pmgr "devices"/"ps-regs"/"reg" from a plain-format
# ioreg dump (ioreg -p IODeviceTree -l -w0), print AVD-related records.
txt = File.read(ARGV[0] || "/tmp/ioreg_dt.txt")
pos = txt.index("pmgr@") or abort "pmgr node not found"
blob = lambda do |key|
  m = txt[pos..-1].match(/"#{key}" = <([0-9a-fA-F]+)>/)
  m && [m[1]].pack("H*")
end
dev = blob.call("devices") or abort "no devices"
ps  = blob.call("ps-regs") or abort "no ps-regs"
reg = blob.call("reg") or abort "no reg"
puts "devices=#{dev.bytesize}B (#{dev.bytesize / 48} recs) ps-regs=#{ps.bytesize}B reg=#{reg.bytesize}B (#{reg.bytesize / 16} regions)"
regs = []
(0...(reg.bytesize / 16)).each { |i| regs << reg[i * 16, 16].unpack1("Q") }
psu = ps.unpack("L*")
psbase = lambda do |idx|
  tri = idx.to_i
  regs[psu[3 * tri].to_i] + psu[3 * tri + 1].to_i
end
recs = []
(0...(dev.bytesize / 48)).each do |i|
  r = dev[i * 48, 48]
  recs << {
    flags: r.getbyte(0), id1: r.getbyte(3),
    p16: [r[4, 2].unpack1("S"), r[6, 2].unpack1("S")],
    off: r.getbyte(10), psidx: r.getbyte(11),
    id: r[26, 2].unpack1("S"), name: r[32, 16].unpack1("Z*"),
  }
end
byid = {}
recs.each { |r| byid[r[:id]] ||= r }
addr = ->(r) { psbase.call(r[:psidx]) + (r[:off] << 3) + 0x200000000 }
out = []
out << "pmgr reg regions: #{regs.size} (first 4: #{regs.first(4).map { |a| '0x%x' % a }.join(', ')})"
out << "ps-regs triplets: #{(psu.size / 3).to_i}"
out << "== validation anchors =="
{ "AVD_SYS" => 0x410, "MMX" => 0x358, "FPWM1" => 0x1e0, "DPA1" => 0x2f0 }.each do |n, exp|
  r = recs.find { |x| x[:name] == n }
  next unless r
  a = addr.call(r)
  out << format("  %-10s id=0x%04x addr=0x%x %s", n, r[:id], a, a == 0x23b700000 + exp ? "MATCH" : "MISMATCH exp 0x#{(0x23b700000 + exp).to_s(16)}")
end
out << "== avd clock-gates 0x12b/0x12c/0x12d, dart gate 0x145 =="
[0x12b, 0x12c, 0x12d, 0x145].each do |gid|
  r = byid[gid]
  unless r
    out << format("  0x%04x NOT FOUND", gid)
    next
  end
  out << format("  id=0x%04x %-16s flags=0x%02x %s", gid, r[:name], r[:flags], (r[:flags] & 0x10) != 0 ? "VIRTUAL" : "")
  r[:p16].each do |p|
    pr = byid[p]
    next unless pr
    out << format("    parent 0x%04x %-16s addr=0x%x %s", p, pr[:name], addr.call(pr), (pr[:flags] & 0x10) != 0 ? "VIRTUAL" : "")
  end
end
out << "== avd clock-ids 0x15d lookup =="
r = byid[0x15d]
if r
  out << format("  id=0x15d %-16s addr=0x%x flags=0x%02x %s psidx=%d off<<3=0x%x", r[:name], addr.call(r), r[:flags], (r[:flags] & 0x10) != 0 ? "VIRTUAL" : "", r[:psidx], r[:off] << 3)
else
  out << "  0x15d is NOT a pmgr device id"
end
File.write("ioreg_pmgr_devices_decoded.txt", out.join("\n") + "\n")
puts out.join("\n")
