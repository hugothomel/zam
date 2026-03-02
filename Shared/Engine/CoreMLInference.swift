import Accelerate
import CoreML
import Foundation

/// Wraps a compiled CoreML model for inference.
final class CoreMLInference: @unchecked Sendable {
    private let model: MLModel

    /// Load a compiled .mlmodelc model from disk.
    init(compiledModelURL: URL) throws {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        self.model = try MLModel(contentsOf: compiledModelURL, configuration: config)
    }

    /// Run prediction with the given feature provider and return the output.
    func predict(inputs: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: inputs)
    }

    /// Convenience: run prediction with a dictionary of MLMultiArrays.
    func predict(feeds: [String: MLMultiArray]) throws -> MLFeatureProvider {
        let provider = try MLDictionaryFeatureProvider(dictionary: feeds)
        return try model.prediction(from: provider)
    }

    // MARK: - MLMultiArray Helpers

    /// Create a Float32 MLMultiArray with given shape.
    static func makeArray(shape: [Int], dataType: MLMultiArrayDataType = .float32) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dataType)
    }

    /// Get a typed pointer to the underlying MLMultiArray data.
    static func floatPointer(_ array: MLMultiArray) -> UnsafeMutablePointer<Float> {
        array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
    }

    /// Copy Float array data into an MLMultiArray.
    static func copyToArray(_ src: [Float], dest: MLMultiArray) {
        let ptr = floatPointer(dest)
        src.withUnsafeBufferPointer { srcBuf in
            ptr.update(from: srcBuf.baseAddress!, count: min(src.count, dest.count))
        }
    }

    /// Copy UnsafeBufferPointer<Float> into an MLMultiArray.
    static func copyToArray(_ src: UnsafeBufferPointer<Float>, dest: MLMultiArray) {
        let ptr = floatPointer(dest)
        ptr.update(from: src.baseAddress!, count: min(src.count, dest.count))
    }

    /// Extract Float data from an MLMultiArray output, handling Float16 → Float32 conversion.
    static func extractFloats(from array: MLMultiArray) -> [Float] {
        let count = array.count
        if array.dataType == .float16 {
            let raw = array.dataPointer.bindMemory(to: UInt16.self, capacity: count)
            var result = [Float](repeating: 0, count: count)
            // Use vImageConvert for batch Float16 → Float32
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
            result.withUnsafeMutableBufferPointer { dstBuf in
                var dst = vImage_Buffer(data: dstBuf.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            }
            return result
        } else {
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
    }
}
