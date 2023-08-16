// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

struct AttributedTextBlock {
    let content: String
    let font: Font?
    let color: Color?
}

public struct AttributedText: View {
    var attributedText: NSAttributedString?
    
    private var descriptions: [AttributedTextBlock] = []
    
    public init(_ attributedText: NSAttributedString?) {
        self.attributedText = attributedText
        
        self.extractDescriptions()
    }
    
    private mutating func extractDescriptions()  {
        if let text = attributedText {
            text.enumerateAttributes(in: NSMakeRange(0, text.length), options: [], using: { (attribute, range, stop) in
                let substring = (text.string as NSString).substring(with: range)
                let font =  (attribute[.font] as? UIFont).map { Font($0) }
                let color = (attribute[.foregroundColor] as? UIColor).map { Color($0) }
                descriptions.append(AttributedTextBlock(content: substring,
                                                        font: font,
                                                        color: color))
            })
        }
    }
    
    public var body: some View {
        let _ = print(descriptions)
        descriptions.map { description in
            var text: Text = Text(description.content)
            if let font: Font = description.font { text = text.font(font) }
            if let color: Color = description.color { text = text.foregroundColor(color) }
            return text
        }.reduce(Text("")) { (result, text) in
            result + text
        }
    }
}
