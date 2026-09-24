import Darwin

/// A `mach_timebase_info` ratio: `nanoseconds = ticks × numer / denom`.
///
/// Intel Macs report 1/1 (ticks are nanoseconds). Apple silicon reports
/// 125/3: a 24 MHz tick (41.666… ns), so ticks are **not** nanoseconds
/// (plan §1.6).
public struct HostTimebase: Sendable, Hashable {
    public var numer: UInt32
    public var denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        self.numer = numer
        self.denom = max(denom, 1)
    }

    /// 1 tick = 1 ns.
    public static let nanoseconds = HostTimebase(numer: 1, denom: 1)
    /// Apple silicon's 24 MHz tick.
    public static let appleSilicon24MHz = HostTimebase(numer: 125, denom: 3)

    /// This machine's timebase.
    public static let current: HostTimebase = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return .nanoseconds }
        return HostTimebase(numer: info.numer, denom: info.denom)
    }()

    /// Ticks per second (24 000 000 on Apple silicon).
    public var ticksPerSecond: Double { 1e9 * Double(denom) / Double(numer) }

    /// Exact integer nanoseconds (128-bit intermediate, no overflow for any
    /// realistic uptime).
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        guard product.high < UInt64(denom) else { return .max }
        let (quotient, _) = UInt64(denom).dividingFullWidth(product)
        return quotient
    }

    public func seconds(fromTicks ticks: UInt64) -> Double {
        // Split to keep precision for large tick counts.
        let ns = nanoseconds(fromTicks: ticks)
        return Double(ns / 1_000_000_000) + Double(ns % 1_000_000_000) / 1e9
    }

    /// Nearest tick count for `seconds` (negative → 0).
    public func ticks(fromSeconds seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let ticks = (seconds * 1e9 * Double(denom) / Double(numer)).rounded()
        return ticks >= Double(UInt64.max) ? .max : UInt64(ticks)
    }
}

/// Host-clock helpers. "Host seconds" = `mach_absolute_time` converted to
/// seconds; the same clock as `CMClockGetHostTimeClock()` (SCStream buffers),
/// `NSEvent.timestamp` and `CGEvent.timestamp` (after conversion). All
/// recording metadata is stamped in host seconds, then mapped to media time
/// by `RecordingTimeline`.
public enum HostTime {
    /// Current host time in seconds.
    public static func nowSeconds(timebase: HostTimebase = .current) -> Double {
        timebase.seconds(fromTicks: mach_absolute_time())
    }

    /// Current host time in ticks.
    public static func nowTicks() -> UInt64 { mach_absolute_time() }

    public static func seconds(fromMachTicks ticks: UInt64, timebase: HostTimebase = .current) -> Double {
        timebase.seconds(fromTicks: ticks)
    }

    public static func machTicks(fromSeconds seconds: Double, timebase: HostTimebase = .current) -> UInt64 {
        timebase.ticks(fromSeconds: seconds)
    }

    /// `CGEvent.timestamp` (`CGEventTimestamp`) is in mach ticks.
    public static func seconds(fromCGEventTimestamp timestamp: UInt64, timebase: HostTimebase = .current) -> Double {
        timebase.seconds(fromTicks: timestamp)
    }

    /// `NSEvent.timestamp` is already seconds since boot on the host clock;
    /// this is the identity, kept so call sites say which source they read.
    public static func seconds(fromNSEventTimestamp timestamp: Double) -> Double {
        timestamp
    }
}
