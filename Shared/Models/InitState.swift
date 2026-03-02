import Foundation

struct InitState: Codable {
    let T: Int?
    let C: Int?
    let H: Int?
    let W: Int?
    let obs_buffer: [Float]
    let act_buffer: [Int32]
}
