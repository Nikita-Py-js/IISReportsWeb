@{
    ConfigDirectory = 'C:\Deploy\IISReports-config'
    WebRoot = 'C:\inetpub\wwwroot\IISReportsV3'
    AgentRoot = 'C:\Services\IISReportsAgentV3'
    SiteName = 'IISReportsV3'
    AppPoolName = 'IISReportsV3'
    SqlServer = 'localhost'
    Database = 'IISReports'
    SqlAuthentication = 'WindowsLocal'
    Editor = 'REPLACE_SERVER\REPLACE_OPERATOR'
    Readers = ''
    PublicUrl = 'http://localhost:801/'
    BindingMode = 'LocalHttp'
    BindingUrl = ''
    CertificateThumbprint = ''
    TrustSqlCertificate = $false
    AllowCreateDatabase = $true
}
