import Darwin

/// Process-table helpers for owning and cleaning up what tabs launch.
enum ProcessTree {
    struct Info { var parent: pid_t; var terminal: dev_t }

    /// Every process with its parent and controlling terminal, from one `sysctl(KERN_PROC_ALL)` snapshot.
    static func snapshot() -> [pid_t: Info] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        var map: [pid_t: Info] = [:]
        for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            map[p.kp_proc.p_pid] = Info(parent: p.kp_eproc.e_ppid, terminal: p.kp_eproc.e_tdev)
        }
        return map
    }

    static func parents() -> [pid_t: pid_t] { snapshot().mapValues(\.parent) }

    /// Descendants of `root` that share its controlling terminal, deepest first: what closing a terminal
    /// window ends. Detached daemons started from the tab, such as Claude's background-session daemon, and
    /// everything under them, are left alone.
    static func terminalDescendants(of root: pid_t) -> [pid_t] {
        descendants(of: root, in: snapshot())
    }

    static func descendants(of root: pid_t, in processes: [pid_t: Info]) -> [pid_t] {
        guard let terminal = processes[root]?.terminal else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, info) in processes { children[info.parent, default: []].append(pid) }
        var result: [pid_t] = []
        func walk(_ pid: pid_t) {
            for child in children[pid] ?? [] where processes[child]?.terminal == terminal {
                walk(child); result.append(child)
            }
        }
        walk(root)
        return result
    }

    /// Exited but not yet reaped by its parent.
    static func isZombie(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == SZOMB
    }

    /// Direct children of this app: the shells it started for tabs.
    static func ownChildren() -> [pid_t] {
        let me = getpid()
        return parents().compactMap { $0.value == me ? $0.key : nil }
    }
}
