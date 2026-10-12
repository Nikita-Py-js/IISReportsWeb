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
    PublicUrl = 'https://reports.example.test:8443/'
    BindingMode = 'ReverseProxy'
    BindingUrl = 'http://127.0.0.1:801/'
    CertificateThumbprint = ''
    TrustSqlCertificate = $false
    AllowCreateDatabase = $true
}
