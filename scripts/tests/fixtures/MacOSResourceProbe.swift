import Darwin
import Foundation

let pid = Int32(CommandLine.arguments[1])!
var usage = rusage_info_v4()
let result = withUnsafeMutablePointer(to: &usage) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
    }
}
guard result == 0 else { fatalError("proc_pid_rusage failed: \(errno)") }
let data = try JSONSerialization.data(withJSONObject: [
    "footprint": usage.ri_phys_footprint,
    "wakeups": usage.ri_interrupt_wkups,
])
print(String(decoding: data, as: UTF8.self))
