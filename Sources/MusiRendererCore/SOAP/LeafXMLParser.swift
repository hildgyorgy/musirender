import Foundation

final class LeafXMLParser: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var currentName: String?
    private var currentText = ""

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
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
