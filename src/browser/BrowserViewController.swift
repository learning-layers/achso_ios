/*

`BrowserViewController` is the parent view controller that contains both CategoriesViewController.swift and VideosViewController.swift .

*/

import UIKit

class BrowserViewController: UISplitViewController, UISplitViewControllerDelegate {
    
    var videosViewController: VideosViewController!
    
    override func viewDidLoad() {

        // Hide the groups always
        self.preferredDisplayMode = .PrimaryHidden
        self.delegate = self
    }

    func splitViewController(svc: UISplitViewController, willChangeToDisplayMode displayMode: UISplitViewControllerDisplayMode) {
        self.videosViewController.splitViewControllerDidChangeDisplayMode()
    }
}
