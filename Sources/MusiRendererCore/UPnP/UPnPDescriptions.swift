import Foundation

public enum UPnPDescriptions {
    static let sinkProtocolInfo = "http-get:*:audio/mp4:*,http-get:*:audio/mpeg:*,http-get:*:audio/aac:*,\(DIDLPlaylist.protocolInfo)"
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
        <action><name>SetNextAVTransportURI</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(input("NextURI", "NextAVTransportURI"))
          \(input("NextURIMetaData", "NextAVTransportURIMetaData"))
        </argumentList></action>
        <action><name>Next</name><argumentList>\(input("InstanceID", "A_ARG_TYPE_InstanceID"))</argumentList></action>
        <action><name>Previous</name><argumentList>\(input("InstanceID", "A_ARG_TYPE_InstanceID"))</argumentList></action>
        <action><name>Pause</name><argumentList>\(input("InstanceID", "A_ARG_TYPE_InstanceID"))</argumentList></action>
        <action><name>Stop</name><argumentList>\(input("InstanceID", "A_ARG_TYPE_InstanceID"))</argumentList></action>
        <action><name>GetTransportSettings</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(output("PlayMode", "CurrentPlayMode"))
          \(output("RecQualityMode", "CurrentRecordQualityMode"))
        </argumentList></action>
        <action><name>SetPlayMode</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(input("NewPlayMode", "CurrentPlayMode"))
        </argumentList></action>
        <action><name>Seek</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(input("Unit", "A_ARG_TYPE_SeekMode"))
          \(input("Target", "A_ARG_TYPE_SeekTarget"))
        </argumentList></action>
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
        <action><name>GetMediaInfo</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(output("NrTracks", "NumberOfTracks"))
          \(output("MediaDuration", "CurrentMediaDuration"))
          \(output("CurrentURI", "AVTransportURI"))
          \(output("CurrentURIMetaData", "AVTransportURIMetaData"))
          \(output("NextURI", "NextAVTransportURI"))
          \(output("NextURIMetaData", "NextAVTransportURIMetaData"))
          \(output("PlayMedium", "PlaybackStorageMedium"))
          \(output("RecordMedium", "RecordStorageMedium"))
          \(output("WriteStatus", "RecordMediumWriteStatus"))
        </argumentList></action>
        <action><name>GetCurrentTransportActions</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(output("Actions", "CurrentTransportActions"))
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        \(state("TransportState", "string", allowed: ["STOPPED", "PLAYING", "TRANSITIONING", "PAUSED_PLAYBACK", "NO_MEDIA_PRESENT"]))
        \(state("TransportStatus", "string", allowed: ["OK", "ERROR_OCCURRED"]))
        \(state("TransportPlaySpeed", "string", allowed: ["1"]))
        \(state("AVTransportURI", "uri"))
        \(state("AVTransportURIMetaData", "string"))
        \(state("NextAVTransportURI", "uri"))
        \(state("NextAVTransportURIMetaData", "string"))
        \(state("NumberOfTracks", "ui4"))
        \(state("CurrentMediaDuration", "string"))
        \(state("PlaybackStorageMedium", "string", allowed: ["NETWORK", "NONE", "NOT_IMPLEMENTED"]))
        \(state("RecordStorageMedium", "string", allowed: ["NOT_IMPLEMENTED"]))
        \(state("RecordMediumWriteStatus", "string", allowed: ["NOT_IMPLEMENTED"]))
        \(state("CurrentTransportActions", "string"))
        \(state("CurrentPlayMode", "string", allowed: ["NORMAL"]))
        \(state("CurrentRecordQualityMode", "string", allowed: ["NOT_IMPLEMENTED"]))
        \(state("CurrentTrack", "ui4"))
        \(state("CurrentTrackDuration", "string"))
        \(state("CurrentTrackMetaData", "string"))
        \(state("CurrentTrackURI", "uri"))
        \(state("RelativeTimePosition", "string"))
        \(state("AbsoluteTimePosition", "string"))
        \(state("RelativeCounterPosition", "i4"))
        \(state("AbsoluteCounterPosition", "i4"))
        \(state("A_ARG_TYPE_InstanceID", "ui4"))
        \(state("A_ARG_TYPE_SeekMode", "string", allowed: ["REL_TIME", "ABS_TIME"]))
        \(state("A_ARG_TYPE_SeekTarget", "string"))
        \(state("LastChange", "string", evented: true))
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
        <action><name>GetMute</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(input("Channel", "A_ARG_TYPE_Channel"))
          \(output("CurrentMute", "Mute"))
        </argumentList></action>
        <action><name>SetMute</name><argumentList>
          \(input("InstanceID", "A_ARG_TYPE_InstanceID"))
          \(input("Channel", "A_ARG_TYPE_Channel"))
          \(input("DesiredMute", "Mute"))
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        \(state("A_ARG_TYPE_InstanceID", "ui4"))
        \(state("A_ARG_TYPE_Channel", "string", allowed: ["Master"]))
        <stateVariable sendEvents="no"><name>Volume</name><dataType>ui2</dataType><allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange></stateVariable>
        \(state("Mute", "boolean"))
        \(state("LastChange", "string", evented: true))
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
        <action><name>GetCurrentConnectionIDs</name><argumentList>
          \(output("ConnectionIDs", "CurrentConnectionIDs"))
        </argumentList></action>
        <action><name>GetCurrentConnectionInfo</name><argumentList>
          \(input("ConnectionID", "A_ARG_TYPE_ConnectionID"))
          \(output("RcsID", "A_ARG_TYPE_RcsID"))
          \(output("AVTransportID", "A_ARG_TYPE_AVTransportID"))
          \(output("ProtocolInfo", "A_ARG_TYPE_ProtocolInfo"))
          \(output("PeerConnectionManager", "A_ARG_TYPE_ConnectionManager"))
          \(output("PeerConnectionID", "A_ARG_TYPE_ConnectionID"))
          \(output("Direction", "A_ARG_TYPE_Direction"))
          \(output("Status", "A_ARG_TYPE_ConnectionStatus"))
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        \(state("SourceProtocolInfo", "string", evented: true))
        \(state("SinkProtocolInfo", "string", evented: true))
        \(state("CurrentConnectionIDs", "string", evented: true))
        \(state("A_ARG_TYPE_ConnectionID", "i4"))
        \(state("A_ARG_TYPE_RcsID", "i4"))
        \(state("A_ARG_TYPE_AVTransportID", "i4"))
        \(state("A_ARG_TYPE_ProtocolInfo", "string"))
        \(state("A_ARG_TYPE_ConnectionManager", "string"))
        \(state("A_ARG_TYPE_Direction", "string", allowed: ["Input", "Output"]))
        \(state("A_ARG_TYPE_ConnectionStatus", "string", allowed: ["OK", "ContentFormatMismatch", "InsufficientBandwidth", "UnreliableChannel", "Unknown"]))
      </serviceStateTable>
    </scpd>
    """

    public static func invalidActionSOAP() -> String {
        errorSOAP(code: 401, description: "Invalid Action")
    }

    public static func errorSOAP(code: Int, description: String) -> String {
        xmlHeader + """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><s:Fault>
            <faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
            <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode><errorDescription>\(xmlEscape(description))</errorDescription></UPnPError></detail>
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
    private static func state(_ name: String, _ type: String, allowed: [String] = [], evented: Bool = false) -> String {
        let values = allowed.isEmpty ? "" : "<allowedValueList>" + allowed.map { "<allowedValue>\($0)</allowedValue>" }.joined() + "</allowedValueList>"
        return "<stateVariable sendEvents=\"\(evented ? "yes" : "no")\"><name>\(name)</name><dataType>\(type)</dataType>\(values)</stateVariable>"
    }
    static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
