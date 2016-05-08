//
//  AppDelegate.swift
//  GPUTextComparison
//
//  Created by Litherum on 4/10/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var window: NSWindow!

    @IBOutlet var viewController: NSViewController!

    func applicationDidFinishLaunching(aNotification: NSNotification) {
        guard let textViewController = viewController as? TextViewController else {
            fatalError()
        }
        textViewController.frames = layout()
        // Insert code here to initialize your application
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
    }


}

