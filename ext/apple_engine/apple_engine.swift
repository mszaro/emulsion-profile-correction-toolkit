// The Metal half of `filmscan --engine apple`: compiles the per-pixel kernels
// lib/film_scan/fused.rb writes and runs them over float images in memory.
// `rake apple_engine` builds it into libexec/ as a library Ruby loads by FFI.
//
// Every kernel has the same shape: its inputs as buffers 0 to n-1, the
// constants at n, the output at n + 1 and the pixel count at n + 2, with one
// thread a pixel. Bands are interleaved, as libvips keeps them.
import Foundation
import Metal

final class Engine {
    let device: MTLDevice
    let queue: MTLCommandQueue

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
    }
}

let page = Int(getpagesize())

func rounded(_ length: Int) -> Int {
    (length + page - 1) / page * page
}

func say(_ message: String, into error: UnsafeMutablePointer<CChar>, _ capacity: Int) {
    let bytes = Array(message.utf8CString.prefix(capacity - 1)) + [0]
    bytes.withUnsafeBufferPointer { error.update(from: $0.baseAddress!, count: bytes.count) }
}

@_cdecl("fs_engine_open")
public func engineOpen() -> UnsafeMutableRawPointer? {
    guard let engine = Engine() else { return nil }
    return Unmanaged.passRetained(engine).toOpaque()
}

// Page aligned and rounded up to whole pages, so the GPU reads and writes it
// in place rather than through a copy.
@_cdecl("fs_engine_alloc")
public func engineAlloc(_ length: Int) -> UnsafeMutableRawPointer? {
    var memory: UnsafeMutableRawPointer?
    return posix_memalign(&memory, page, rounded(max(length, 1))) == 0 ? memory : nil
}

@_cdecl("fs_engine_free")
public func engineFree(_ memory: UnsafeMutableRawPointer?) {
    free(memory)
}

// Precise maths, since a kernel stands in for libvips arithmetic and has to
// agree with it to the last bit it can.
@_cdecl("fs_engine_compile")
public func engineCompile(_ handle: UnsafeMutableRawPointer, _ source: UnsafePointer<CChar>,
                          _ reason: UnsafeMutablePointer<CChar>, _ capacity: Int) -> UnsafeMutableRawPointer? {
    let engine = Unmanaged<Engine>.fromOpaque(handle).takeUnretainedValue()
    let options = MTLCompileOptions()
    options.mathMode = .safe
    options.mathFloatingPointFunctions = .precise
    do {
        let library = try engine.device.makeLibrary(source: String(cString: source), options: options)
        guard let function = library.makeFunction(name: "fused") else {
            say("no kernel called fused", into: reason, capacity)
            return nil
        }
        let state = try engine.device.makeComputePipelineState(function: function)
        return Unmanaged.passRetained(state as AnyObject).toOpaque()
    } catch {
        say(String(describing: error), into: reason, capacity)
        return nil
    }
}

// Memory this library allocated is used in place; anything else is copied.
func buffer(_ device: MTLDevice, _ pointer: UnsafeMutableRawPointer, _ length: Int, owned: Bool) -> MTLBuffer? {
    if owned {
        return device.makeBuffer(bytesNoCopy: pointer, length: rounded(length), options: .storageModeShared,
                                 deallocator: nil)
    }
    return device.makeBuffer(bytes: pointer, length: length, options: .storageModeShared)
}

// 0 when the kernel ran, otherwise what went wrong, with the reason in error.
@_cdecl("fs_engine_run")
public func engineRun(_ handle: UnsafeMutableRawPointer, _ kernel: UnsafeMutableRawPointer,
                      _ inputs: UnsafePointer<UnsafeMutableRawPointer?>, _ lengths: UnsafePointer<Int>,
                      _ owned: UnsafePointer<UInt8>, _ count: Int32,
                      _ constants: UnsafeRawPointer?, _ constantsLength: Int,
                      _ output: UnsafeMutableRawPointer, _ outputLength: Int, _ pixels: UInt32,
                      _ error: UnsafeMutablePointer<CChar>, _ capacity: Int) -> Int32 {
    let engine = Unmanaged<Engine>.fromOpaque(handle).takeUnretainedValue()
    guard let state = Unmanaged<AnyObject>.fromOpaque(kernel).takeUnretainedValue() as? MTLComputePipelineState
    else {
        say("not a kernel", into: error, capacity)
        return 1
    }
    let device = engine.device
    var buffers: [MTLBuffer] = []
    for i in 0..<Int(count) {
        guard let pointer = inputs[i], let input = buffer(device, pointer, lengths[i], owned: owned[i] != 0) else {
            say("input \(i) could not be given to the GPU", into: error, capacity)
            return 2
        }
        buffers.append(input)
    }
    var none: Float = 0
    let table = constantsLength > 0 && constants != nil
        ? device.makeBuffer(bytes: constants!, length: constantsLength, options: .storageModeShared)
        : device.makeBuffer(bytes: &none, length: 4, options: .storageModeShared)
    guard let table, let out = buffer(device, output, outputLength, owned: true),
          let command = engine.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
        say("the GPU would not take the work", into: error, capacity)
        return 3
    }
    encoder.setComputePipelineState(state)
    for (i, input) in buffers.enumerated() {
        encoder.setBuffer(input, offset: 0, index: i)
    }
    encoder.setBuffer(table, offset: 0, index: Int(count))
    encoder.setBuffer(out, offset: 0, index: Int(count) + 1)
    var n = pixels
    encoder.setBytes(&n, length: 4, index: Int(count) + 2)
    let width = min(state.maxTotalThreadsPerThreadgroup, 256)
    encoder.dispatchThreads(MTLSize(width: Int(pixels), height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else {
        say(command.error.map { String(describing: $0) } ?? "the kernel did not finish", into: error, capacity)
        return 4
    }
    return 0
}
