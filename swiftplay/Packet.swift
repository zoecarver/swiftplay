//
//  Packet.swift
//  swiftplay
//
//  Created by Zoe IAMZOE.io on 8/14/18.
//  Copyright © 2018 Zoe IAMZOE.io. All rights reserved.
//

import Foundation

public struct Packet {
    var data = Data()
    var index = UInt16(0)
    var timeStamp = UInt32(0)
}
