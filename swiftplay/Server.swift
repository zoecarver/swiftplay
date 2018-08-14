//
//  Server.swift
//  swiftplay
//
//  Created by Zoe IAMZOE.io on 8/14/18.
//  Copyright © 2018 Zoe IAMZOE.io. All rights reserved.
//

import Foundation
import AudioToolbox
import CocoaAsyncSocket
import Security
import CommonCrypto

public struct ServerConfig {
    
    private var UID: UInt8! = 1
    
    // TOOD: these should all be public static lets
    let txtFields = ["et": "1", "sf": "0x4", "tp": "UDP", "vn": "3", "cn": "1", "md": "0,1,2"]
    let txtRecord: [String: Data]!
    
    let macAddress: [UInt8] = [
        10,
        10,
        10,
        10,
        10,
        /*UID TODO:*/ 1
    ]
    
    let serviceType: String! = "_raop._tcp."
    let serviceDomain: String! = ""
    
    let cookie: [UInt8] = [0, 0, 1, 96, 0, 16, 40, 10, 14, 2, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 172, 68]
    
    let bufferCount: Int! = 3
    
    let bufferSize: UInt32! = 1536
    
    init() {
        //TODO: when this is static put it inline
        self.txtRecord = Dictionary(uniqueKeysWithValues: txtFields.map { arg in
            let (key, val) = arg
            return (key, val.data(using: .utf8)!) // ususally wouldnt force cast but here its okay
        })
    }
}

public protocol Server {
    var service: NetService? { get set }
    var tcpSockets: [GCDAsyncSocket]! { get set }
    var udpSockets: [GCDAsyncUdpSocket]! { get set }
    var address: Data? { get set }
    
    //    var controller: Controller! { get }
    var key: Data? { get set }
    var IV: Data? { get set }
    
    var process: DispatchQueue! { get }
    var callback: DispatchQueue! { get }
    
    var serverName: String! { get }
    
    //    var port: UInt16! { get }
    var cPort: UInt16! { get }
    var tPort: UInt16! { get }
    
    var track: Track! { get set }
    
    func listen()
}
