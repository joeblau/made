//
//  TextViewController+FindPanelTarget.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/16/25.
//

import AppKit
import CodeEditTextView

extension TextViewController: FindPanelTarget {
    var findPanelTargetView: NSView {
        textView
    }

    func findPanelWillShow(panelHeight: CGFloat) {
        updateFindPanelInsetsPreservingVisibleText()
    }

    func findPanelWillHide(panelHeight: CGFloat) {
        updateFindPanelInsetsPreservingVisibleText()
    }

    func findPanelModeDidChange(to mode: FindPanelMode) {
        updateFindPanelInsetsPreservingVisibleText()
    }

    private func updateFindPanelInsetsPreservingVisibleText() {
        let previousInset = scrollView.contentInsets.top
        let origin = scrollView.contentView.bounds.origin
        updateContentInsets()
        let delta = scrollView.contentInsets.top - previousInset
        guard delta != 0 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y - delta))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var emphasisManager: EmphasisManager? {
        textView?.emphasisManager
    }
}
