using System;
using System.Web;
namespace IISReports
{
    public sealed class ApiFailure : Exception
    {
        public readonly int Status; public readonly string Code;
        public ApiFailure(int status,string code,string message):base(message){Status=status;Code=code;}
    }
    // Access control is delegated to IIS/network configuration. No editor lists, cookies,
    // MachineKey tokens or PublicOrigin matching. Do not expose an anonymous panel publicly.
    public static class AccessControl
    {
        public static string Mode { get { return "iis"; } }
        public static bool Local(HttpContext c){return c.Request.IsLocal;}
        public static bool Authenticated(HttpContext c){return c.User!=null&&c.User.Identity!=null&&c.User.Identity.IsAuthenticated;}
        public static string Principal(HttpContext c){return Authenticated(c)?c.User.Identity.Name:"IIS visitor";}
        public static bool CanEdit(HttpContext c){return true;}
        public static void RequireRead(HttpContext c){}
        public static void RequireEditor(HttpContext c){}
        public static object IdentityInfo(HttpContext c)
        {return new{mode=Mode,identity=Principal(c),isAuthenticated=Authenticated(c),canRead=true,canEdit=true,
            processIdentity=System.Security.Principal.WindowsIdentity.GetCurrent().Name,version="3.2.0-simple",
            protection="IIS/network access control; POST + custom header; no CORS"};}
        public static void RequirePost(HttpContext c)
        {
            if(c.Request.HttpMethod!="POST") {c.Response.AppendHeader("Allow","POST");throw new ApiFailure(405,"post_required","Use POST.");}
            // Browsers cannot add this header cross-origin without a successful CORS preflight.
            // It is not a password or an authentication mechanism.
            if(c.Request.Headers["X-IISReports-Request"]!="1")throw new ApiFailure(403,"request_header","Missing X-IISReports-Request: 1.");
        }
        public static void ResponseHeaders(HttpContext c)
        {
            c.Response.TrySkipIisCustomErrors=true;
            c.Response.Cache.SetCacheability(HttpCacheability.NoCache);c.Response.Cache.SetNoStore();
            c.Response.Headers["X-Content-Type-Options"]="nosniff";
            c.Response.Headers["X-Frame-Options"]="DENY";
        }
    }
}
