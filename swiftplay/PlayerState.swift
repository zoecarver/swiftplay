//
//  PlayerState.swift
//  swiftplay
//
//  Created by Zoe IAMZOE.io on 8/14/18.
//  Copyright © 2018 Zoe IAMZOE.io. All rights reserved.
//

import Foundation
import AudioToolbox

public struct PlayerState { // wish that this could just be static!
    var queue: AudioQueueRef?
    var buffers: [AudioQueueBufferRef]! = [AudioQueueBufferRef]()
    var packets = [Packet](repeating: Packet(), count: 1024)
    var packetsRead = Int64(0)
    var packetsWritten = Int64(0)
    var queueTime = UInt32(0)
    var sessionTime = UInt32(0)
}
