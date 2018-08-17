//
//  Utils.swift
//  swiftplay
//
//  Created by Zoe IAMZOE.io on 8/14/18.
//  Copyright © 2018 Zoe IAMZOE.io. All rights reserved.
//

import Foundation

public class Utils {
    public static func padBase64(string input: String) -> String {
        var paddedInput = input
        
        while paddedInput.count % 4 != 0 {
            paddedInput += "="
        }
        
        return paddedInput
    }
    
    public static func makeRange(_ a: Int, _ b: Int) -> Range<Int> {
        guard let range = Range(NSMakeRange(a, b)) else { // TODO: use good range
            print("Error [make range] : invalid range for value")
            return Range(NSMakeRange(1, 1))!
        }
        
        return range
    }
    
    public static func fromByteArray<T>(_ value: [UInt8], _: T.Type) -> T {
        return value.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: T.self, capacity: 1) {
                $0.pointee
            }
        }
    }
}

extension Data {
    func bytesForRange <T: Numeric> (_ a: Int, _ b: Int, count: Int) -> T {
        let bytes = self.subdata(in: Utils.makeRange(a, b)).withUnsafeBytes { byte in
            [T](UnsafeBufferPointer(start: byte, count: count))
        }
        return UnsafePointer<T>(bytes).pointee
    }
    
    func bytes <T: Numeric> (withCount count: Int) -> T {
        let bytes = self.withUnsafeBytes { byte in
            [T](UnsafeBufferPointer(start: byte, count: count))
        }
        return UnsafePointer<T>(bytes).pointee
    }
}

extension UnsafeMutableRawPointer {
    func mutable <T> () -> UnsafeMutablePointer<T> {
        return UnsafeMutablePointer<T>(OpaquePointer(self))
    }
}
