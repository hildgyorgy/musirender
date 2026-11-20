import Foundation

public enum UPnPDescriptions {
    public static let deviceType = "urn:schemas-upnp-org:device:MediaRenderer:1"
    public static let avTransportType = "urn:schemas-upnp-org:service:AVTransport:1"
    public static let renderingControlType = "urn:schemas-upnp-org:service:RenderingControl:1"
    public static let connectionManagerType = "urn:schemas-upnp-org:service:ConnectionManager:1"

    public static func device(configuration: RendererConfiguration) -> String {
        let name = xmlEscape(configuration.friendlyName)
        return xmlHeader + """
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <specVersion><major>1</major><minor>1</minor></specVersion>
          <device>
            <deviceType>\(deviceType)</deviceType>
            <friendlyName>\(name)</friendlyName>
            <manufacturer>MusiRenderer Open Source Project</manufacturer>
            <modelDescription>Native macOS UPnP audio renderer</modelDescription>
            <modelName>MusiRenderer</modelName>
            <modelNumber>0.1</modelNumber>
            <UDN>uuid:\(configuration.uuid.uuidString.lowercased())</UDN>
            <serviceList>
              \(service(type: connectionManagerType, id: "urn:upnp-org:serviceId:ConnectionManager", slug: "connectionmanager"))
              \(service(type: avTransportType, id: "urn:upnp-org:serviceId:AVTransport", slug: "avtransport"))
              \(service(type: renderingControlType, id: "urn:upnp-org:serviceId:RenderingControl", slug: "renderingcontrol"))
            </serviceList>
          </device>
        </root>
        """
    }

    public static let avTransport = xmlHeader + """
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <actionList>
        <action><name>SetAVTransportURI</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(input("CurrentURI", "AVTransportURI"))
          \(input("CurrentURIMetaData", "AVTransportURIMetaData"))
        </argumentList></action>
        <action><name>Play</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(input("Speed", "TransportPlaySpeed"))
        </argumentList></action>
        <action><name>Pause</name><argumentList>\(input("InstanceID", "A_ARG_TYPE_InstanceID"))</argumentList></action>
        <action><name>Stop</name><argumentList>\(input("InstanceID", "A_ARG_TYPE_InstanceID"))</argumentList></action>
        <action><name>GetTransportInfo</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(output("CurrentTransportState", "TransportState"))
          \(output("CurrentTransportStatus", "TransportStatus"))
          \(output("CurrentSpeed", "TransportPlaySpeed"))
        </argumentList></action>
        <action><name>GetPositionInfo</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(output("Track", "CurrentTrack"))
          \(output("TrackDuration", "CurrentTrackDuration"))
          \(output("TrackMetaData", "CurrentTrackMetaData"))
          \(output("TrackURI", "CurrentTrackURI"))
          \(output("RelTime", "RelativeTimePosition"))
          \(output("AbsTime", "AbsoluteTimePosition"))
          \(output("RelCount", "RelativeCounterPosition"))
          \(output("AbsCount", "AbsoluteCounterPosition"))
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        \(state("TransportState", "string", allowed: ["STOPPED", "PLAYING", "TRANSITIONING", "PAUSED_PLAYBACK", "NO_MEDIA_PRESENT"]))
        \(state("TransportStatus", "string", allowed: ["OK", "ERROR_OCCURRED"]))
        \(state("TransportPlaySpeed", "string", allowed: ["1"]))
        \(state("AVTransportURI", "uri"))
        \(state("AVTransportURIMetaData", "string"))
        \(state("CurrentTrack", "ui4"))
        \(state("CurrentTrackDuration", "string"))
        \(state("CurrentTrackMetaData", "string"))
        \(state("CurrentTrackURI", "uri"))
        \(state("RelativeTimePosition", "string"))
        \(state("AbsoluteTimePosition", "string"))
        \(state("RelativeCounterPosition", "i4"))
        \(state("AbsoluteCounterPosition", "i4"))
        \(state("A_ARG_TYPE_InstanceID", "ui4"))
      </serviceStateTable>
    </scpd>
    """

    public static let renderingControl = xmlHeader + """
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <actionList>
        <action><name>GetVolume</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(input("Channel", "A_ARG_TYPE_Channel"))
          \(output("CurrentVolume", "Volume"))
        </argumentList></action>
        <action><name>SetVolume</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(input("Channel", "A_ARG_TYPE_Channel"))
          \(input("DesiredVolume", "Volume"))
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        \(state("A_ARG_TYPE_InstanceID", "ui4"))
        \(state("A_ARG_TYPE_Channel", "string", allowed: ["Master"]))
        <stateVariable sendEvents="yes"><name>Volume</name><dataType>ui2</dataType><allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange></stateVariable>
      </serviceStateTable>
    </scpd>
    """

    public static let connectionManager = xmlHeader + """
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <actionList>
        <action><name>GetProtocolInfo</name><argumentList>
          \(output("Source", "SourceProtocolInfo"))
          \(output("Sink", "SinkProtocolInfo"))
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        \(state("SourceProtocolInfo", "string"))
        \(state("SinkProtocolInfo", "string"))
      </serviceStateTable>
    </scpd>
    """

    public static func invalidActionSOAP() -> String {
        xmlHeader + """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><s:Fault>
            <faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
            <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>401</errorCode><errorDescription>Invalid Action</errorDescription></UPnPError></detail>
          </s:Fault></s:Body>
        </s:Envelope>
        """
    }

    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"

    private static func service(type: String, id: String, slug: String) -> String {
        """
        <service><serviceType>\(type)</serviceType><serviceId>\(id)</serviceId><SCPDURL>/upnp/\(slug)/scpd.xml</SCPDURL><controlURL>/upnp/\(slug)/control</controlURL><eventSubURL>/upnp/\(slug)/event</eventSubURL></service>
        """
    }

    private static func input(_ name: String, _ state: String) -> String { argument(name, "in", state) }
    private static func output(_ name: String, _ state: String) -> String { argument(name, "out", state) }
    private static func argument(_ name: String, _ direction: String, _ state: String) -> String {
        "<argument><name>\(name)</name><direction>\(direction)</direction><relatedStateVariable>\(state)</relatedStateVariable></argument>"
    }
    private static func state(_ name: String, _ type: String, allowed: [String] = []) -> String {
        let values = allowed.isEmpty ? "" : "<allowedValueList>" + allowed.map { "<allowedValue>\($0)</allowedValue>" }.joined() + "</allowedValueList>"
        return "<stateVariable sendEvents=\"no\"><name>\(name)</name><dataType>\(type)</dataType>\(values)</stateVariable>"
    }
    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
