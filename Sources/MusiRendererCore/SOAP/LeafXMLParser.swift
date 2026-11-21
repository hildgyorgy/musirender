import Foundation

final class LeafXMLParser: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var currentName: String?
    private var currentText = ""

    init(data: Data) {
        super.init()
        guard let text = String(data: data, encoding: .utf8), !text.contains("<!DOCTYPE") else { return }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        if !parser.parse() { values.removeAll() }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentName = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentName != nil else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if currentName == elementName {
            values[elementName] = currentText
            currentName = nil
            currentText = ""
        }
    }
}
