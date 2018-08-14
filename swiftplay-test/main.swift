//
//  main.swift
//  swiftplay-test
//
//  Created by Zoe IAMZOE.io on 8/10/18.
//  Copyright © 2018 Zoe IAMZOE.io. All rights reserved.
//

import Foundation
import swiftplay_mac

print("Initializing server...")
let server = AirplayServer()
server.listen()

while true { /* BLOCK */ }
