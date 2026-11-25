import Foundation
import CShim

/// A low-level process snapshot shared by the feasibility probes and daemon.
public struct ProcSnapshot {
    public let pid: Int32
    public let name: String
    public let path: String?
    public let ppid: Int32
    public let startAbstime: UInt64
    public let rusage: cshim_rusage?

    public init(pid: Int32, name: String, path: String?, ppid: Int32, startAbstime: UInt64, rusage: cshim_rusage?) {
        self.pid = pid
        self.name = name
        self.path = path
        self.ppid = ppid
        self.startAbstime = startAbstime
        self.rusage = rusage
    }
}

public enum ProcAPI {
    public static func allPids() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [Int32](repeating: 0, count: Int(n) * 2)
        let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }
        return Array(buf.prefix(Int(got))).filter { $0 > 0 }
    }

    public static func path(for pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is no longer imported by Swift in the
        // macOS 26 SDK. libproc's proc_pidpath(3) contract is still 4 KiB.
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    public static func bsdInfo(for pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard n == Int32(size) else { return nil }
        return info
    }

    public static func name(for pid: Int32) -> String {
        if let info = bsdInfo(for: pid) {
            let comm = name(from: info)
            if !comm.isEmpty { return comm }
        }
        if let p = path(for: pid) { return (p as NSString).lastPathComponent }
        return "pid \(pid)"
    }

    /// The kernel's process name from an already-read `proc_bsdinfo`, or "".
    public static func name(from info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_name) { raw -> String in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// KERN_PROCARGS2: full argv (same-user only without privileges).
    public static func arguments(for pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        guard size > MemoryLayout<Int32>.size else { return nil }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var idx = MemoryLayout<Int32>.size
        while idx < size, buf[idx] != 0 { idx += 1 }
        while idx < size, buf[idx] == 0 { idx += 1 }
        var args: [String] = []
        var cur: [UInt8] = []
        while idx < size, args.count < Int(argc) {
            if buf[idx] == 0 {
                args.append(String(decoding: cur, as: UTF8.self))
                cur = []
            } else {
                cur.append(buf[idx])
            }
            idx += 1
        }
        return args
    }

    /// Working directory via PROC_PIDVNODEPATHINFO.
    public static func cwd(for pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
        guard n > 0 else { return nil }
        let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return cwd.isEmpty ? nil : cwd
    }

    public static func rusage(for pid: Int32) -> cshim_rusage? {
        var ru = cshim_rusage()
        guard cshim_get_rusage(pid, &ru) == 0 else { return nil }
        return ru
    }

    public static func snapshotAll() -> [ProcSnapshot] {
        allPids().map { pid in
            let info = bsdInfo(for: pid)
            let ru = rusage(for: pid)
            return ProcSnapshot(
                pid: pid,
                name: name(for: pid),
                path: path(for: pid),
                ppid: Int32(info?.pbi_ppid ?? 0),
                startAbstime: ru?.proc_start_abstime ?? 0,
                rusage: ru
            )
        }
    }

    /// Listening TCP ports for a pid via fd enumeration.
    public static func listeningPorts(for pid: Int32) -> [UInt16] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let count = Int(bufSize) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        guard got > 0 else { return [] }
        let n = Int(got) / MemoryLayout<proc_fdinfo>.size

        var ports: [UInt16] = []
        for i in 0..<n where fds[i].proc_fdtype == PROX_FDTYPE_SOCKET {
            var sock = socket_fdinfo()
            let sz = Int32(MemoryLayout<socket_fdinfo>.size)
            let r = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &sock, sz)
            guard r == sz else { continue }
            if sock.psi.soi_kind == SOCKINFO_TCP {
                let tcp = sock.psi.soi_proto.pri_tcp
                if tcp.tcpsi_state == TSI_S_LISTEN {
                    let lport = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
                    ports.append(UInt16(bigEndian: lport) == 0 ? lport : UInt16(bigEndian: lport))
                }
            }
        }
        return Array(Set(ports)).sorted()
    }
}
