import Foundation

/// Turns the binary record plus its sidecar into the report the server accepts.
///
/// A pure function on purpose: this is where the fingerprint's inputs are decided — which image an
/// address belongs to, and therefore what `offset` is — and it is the one part of crash reporting
/// that can be tested exhaustively without dying. Everything unsafe already happened in C.
enum CrashAssembly {
    enum Problem: Error, Equatable {
        /// `task_threads` failed inside the handler, so the record cannot say which stack died.
        ///
        /// Dropped rather than repaired. The contract rejects a fatal report that does not have
        /// exactly one crashed thread, and it is right to: picking thread 0 would put a fingerprint —
        /// an issue title, a regression, an alert — on a stack nobody established was the one that
        /// crashed.
        case noCrashedThread
    }

    static func report(record: CrashRecord,
                       sidecar: CrashContextSidecar,
                       crashId: String) throws -> CrashReportWire {
        guard record.threads.contains(where: { $0.crashed }) else { throw Problem.noCrashedThread }

        var state = sidecar.state
        // The two fields the handler could read for itself. They win over the sample, because they
        // describe the moment of death rather than a moment shortly before it.
        state.uptimeMs = Int(record.uptimeMs)
        state.inForeground = record.foreground

        return CrashReportWire(
            crashId: crashId,
            kind: .fatal,
            isFatal: true,
            crashedAt: record.crashedAt,
            sessionId: sidecar.sessionId,
            context: sidecar.context,
            state: state,
            signal: signal(from: record),
            exception: nil,
            hangDurationMs: nil,
            images: sidecar.images,
            threads: threads(record: record, images: sidecar.images),
            breadcrumbs: breadcrumbs(record.crumbs),
            customKeys: sidecar.customKeys
        )
    }

    static func threads(record: CrashRecord, images: [BinaryImageWire]) -> [CrashThreadWire] {
        let index = ImageIndex(images)
        return record.threads.prefix(CrashLimits.maxThreads).map { thread in
            CrashThreadWire(
                index: thread.index,
                name: thread.name,
                crashed: thread.crashed,
                frames: thread.frames.prefix(CrashLimits.maxFramesPerThread).enumerated().map { position, addr in
                    let found = index.image(containing: addr)
                    return CrashFrameWire(
                        n: position,
                        addr: crashHex(addr),
                        image: found?.index,
                        // The whole reason offsets are the identity: an address minus its image's load
                        // address survives ASLR and is identical with or without symbols.
                        offset: found.map { Int(addr - $0.loadAddr) },
                        symbol: nil
                    )
                },
                framesTruncated: thread.framesTruncated || thread.frames.count > CrashLimits.maxFramesPerThread
            )
        }
    }

    static func breadcrumbs(_ crumbs: [CrashRecord.Crumb]) -> [BreadcrumbWire]? {
        let mapped = crumbs.suffix(CrashLimits.maxBreadcrumbs).compactMap { crumb -> BreadcrumbWire? in
            guard let kind = BreadcrumbWire.Kind(byte: crumb.kind) else { return nil }
            return BreadcrumbWire(ts: crumb.ts, kind: kind, name: String(crumb.name.prefix(CrashLimits.breadcrumbNameMaxLength)))
        }
        return mapped.isEmpty ? nil : mapped
    }

    static func signal(from record: CrashRecord) -> CrashSignalWire {
        let fault = record.faultAddr == 0 ? nil : crashHex(record.faultAddr)
        switch record.cause {
        case .mach:
            /*
             * A mach exception carries no signal number, so `name` is the exception's own name rather
             * than a signal guessed from it. `EXC_BAD_ACCESS` does usually arrive as `SIGSEGV`, but
             * "usually" is not something to write into the field a reader will take as measured.
             */
            let name = CrashNames.machException(record.machException)
            return CrashSignalWire(name: name,
                                   code: nil,
                                   machException: name,
                                   machCode: crashHex(record.machCode),
                                   machSubcode: crashHex(record.machSubcode),
                                   faultAddr: fault)
        case .signal, .exception:
            return CrashSignalWire(name: CrashNames.signal(record.signum),
                                   code: record.sigcode == 0 ? nil : String(record.sigcode),
                                   machException: nil,
                                   machCode: nil,
                                   machSubcode: nil,
                                   faultAddr: fault)
        }
    }

    /// Resolves an address to the image it sits in.
    ///
    /// Sorted once and bisected, because a dump is up to forty-eight threads of a hundred and
    /// twenty-eight frames against up to five hundred images — a linear scan per frame is three
    /// hundred thousand comparisons on the launch path of an app that has just crashed.
    struct ImageIndex {
        struct Found {
            var index: Int
            var loadAddr: UInt64
        }

        private let sorted: [(load: UInt64, size: UInt64, index: Int)]

        init(_ images: [BinaryImageWire]) {
            sorted = images.enumerated()
                .compactMap { position, image in
                    guard let load = UInt64(image.loadAddr.dropFirst(2), radix: 16) else { return nil }
                    return (load, UInt64(image.size ?? 0), position)
                }
                .sorted { $0.load < $1.load }
        }

        func image(containing address: UInt64) -> Found? {
            guard !sorted.isEmpty else { return nil }
            var low = 0
            var high = sorted.count - 1
            var candidate: Int?
            while low <= high {
                let mid = (low + high) / 2
                if sorted[mid].load <= address {
                    candidate = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            guard let found = candidate else { return nil }
            let entry = sorted[found]
            /*
             * A size of zero means we never read a __TEXT segment for that image, so the upper bound
             * is unknown. Claiming the address belongs to it anyway would invent an offset, and an
             * invented offset is an invented issue identity — so the frame reports no image, which is
             * a state the contract has a `null` for.
             */
            if entry.size == 0 { return nil }
            guard address < entry.load + entry.size else { return nil }
            return Found(index: entry.index, loadAddr: entry.load)
        }
    }
}

/// Names, never numbers: signal numbers differ per platform, `SIGSEGV` does not.
enum CrashNames {
    static func signal(_ number: Int32) -> String {
        switch number {
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGABRT: return "SIGABRT"
        case SIGTRAP: return "SIGTRAP"
        case SIGSYS: return "SIGSYS"
        case SIGKILL: return "SIGKILL"
        case SIGPIPE: return "SIGPIPE"
        // Not folded into "SIGSEGV" or dropped: an unknown number is reported as itself, so a signal
        // we have not met reaches the panel as an honest unknown rather than as the wrong cause.
        default: return "SIG\(number)"
        }
    }

    static func machException(_ raw: UInt32) -> String {
        switch raw {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 4: return "EXC_EMULATION"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 7: return "EXC_SYSCALL"
        case 8: return "EXC_MACH_SYSCALL"
        case 9: return "EXC_RPC_ALERT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        case 13: return "EXC_CORPSE_NOTIFY"
        default: return "EXC_\(raw)"
        }
    }
}
