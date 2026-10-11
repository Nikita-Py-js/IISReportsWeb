using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using System.Web.Security;
using IISReports.V3;

namespace IISReports
{
    public sealed class ApiFailure:Exception
    {
        public readonly int Status;public readonly string Code;
        public ApiFailure(int status,string code,string message):base(message){Status=status;Code=code;}
    }
    public static class AccessControl
    {
        public static string Mode { get { return Settings.Get("IISReportsAccessMode","windows").ToLowerInvariant(); } }
        private static WindowsIdentity Visitor(HttpContext ctx)
        {
            if(ctx.User==null||ctx.User.Identity==null||!ctx.User.Identity.IsAuthenticated)return null;
            var identity=ctx.User.Identity as WindowsIdentity;
            if(identity!=null&&identity.IsAuthenticated&&!identity.IsAnonymous)return identity;
            // Some modules wrap the principal. Require authenticated, matching IIS logon identity;
            // NEVER fall back to WindowsIdentity.GetCurrent() (the worker process account).
            try
            {
                var logon=ctx.Request.LogonUserIdentity;
                if(!string.IsNullOrEmpty(ctx.Request.ServerVariables["LOGON_USER"])&&logon!=null&&logon.IsAuthenticated&&!logon.IsAnonymous&&
                    string.Equals(logon.Name,ctx.User.Identity.Name,StringComparison.OrdinalIgnoreCase))return logon;
            }catch{ }
            return null;
        }
        public static bool Local(HttpContext ctx)
        {
            return ctx.Request.IsLocal&&string.IsNullOrEmpty(ctx.Request.Headers["Forwarded"])&&
                string.IsNullOrEmpty(ctx.Request.Headers["X-Forwarded-For"])&&string.IsNullOrEmpty(ctx.Request.Headers["X-Forwarded-Host"]);
        }
        public static bool Authenticated(HttpContext ctx){return Visitor(ctx)!=null;}
        public static bool Matches(WindowsIdentity identity,string configured)
        {
            if(identity==null)return false;var principal=new WindowsPrincipal(identity);
            foreach(string raw in configured.Split(new[]{';'},StringSplitOptions.RemoveEmptyEntries))
            {
                string item=raw.Trim();if(item.Length==0)continue;
                if(string.Equals(identity.Name,item,StringComparison.OrdinalIgnoreCase))return true;
                try
                {
                    if(item.StartsWith("S-1-",StringComparison.OrdinalIgnoreCase))
                    { if(principal.IsInRole(new SecurityIdentifier(item)))return true; }
                    else if(principal.IsInRole(item))return true;
                }
                catch(IdentityNotMappedException) { }
                catch(SystemException) { }
            }
            return false;
        }
        public static bool CanEdit(HttpContext ctx)
        {
            if(Mode=="local")return Local(ctx);
            return Mode=="windows"&&Matches(Visitor(ctx),Settings.Get("IISReportsEditors",""));
        }
        public static bool CanRead(HttpContext ctx)
        {
            if(Mode=="local")return Local(ctx);
            return Mode=="windows"&&(CanEdit(ctx)||Matches(Visitor(ctx),Settings.Get("IISReportsReaders","")));
        }
        public static string Principal(HttpContext ctx)
        { var user=Visitor(ctx);return user!=null?user.Name:Mode=="local"&&Local(ctx)?"local-developer":"anonymous"; }
        private static string Subject(HttpContext ctx)
        { var user=Visitor(ctx);return user!=null&&user.User!=null?user.User.Value:Principal(ctx); }
        public static string DenialCode(HttpContext ctx)
        {
            if(Mode!="local"&&Mode!="windows")return "access_mode_invalid";
            if(Mode=="local")return Local(ctx)?null:"local_only";
            if(!Authenticated(ctx))return "authentication_required";
            return CanRead(ctx)?null:"reader_role_required";
        }
        public static void RequireRead(HttpContext ctx)
        {
            string code=DenialCode(ctx);if(code==null)return;
            if(code=="authentication_required")throw new ApiFailure(401,code,"IIS did not supply an authenticated Windows user. Enable Windows Authentication and disable Anonymous Authentication for this application.");
            if(code=="local_only")throw new ApiFailure(403,code,"IISReportsAccessMode is local. Set windows and explicitly authorize the request account in IISReportsEditors/Readers.");
            if(code=="reader_role_required")throw new ApiFailure(403,code,"Windows login succeeded, but this user has no IIS Reports role. Check whoami and IISReportsReaders/Editors.");
            throw new ApiFailure(403,code,"Unknown IISReportsAccessMode. Allowed values: windows, local.");
        }
        public static void RequireEditor(HttpContext ctx)
        { RequireRead(ctx);if(!CanEdit(ctx))throw new ApiFailure(403,"editor_role_required","A Windows login alone is not an operator role. Add the account or group to IISReportsEditors."); }
        public static object IdentityInfo(HttpContext ctx)
        {
            var identity=Visitor(ctx);
            return new { mode=Mode,identity=Principal(ctx),isAuthenticated=identity!=null,
                authenticationType=ctx.User==null||ctx.User.Identity==null?"":ctx.User.Identity.AuthenticationType,
                requestIdentityType=ctx.User==null||ctx.User.Identity==null?"":ctx.User.Identity.GetType().FullName,
                logonUser=ctx.Request.ServerVariables["LOGON_USER"]??"",isLocal=ctx.Request.IsLocal,
                canRead=CanRead(ctx),canEdit=CanEdit(ctx),denialCode=DenialCode(ctx),
                processIdentity=CanEdit(ctx)?WindowsIdentity.GetCurrent().Name:null,
                csrfProtection="user + browser cookie + app path + origin + expiry; MachineKey.Protect",
                version="3.1.0" };
        }
        private static string AppPath(HttpContext ctx)
        { string p=ctx.Request.ApplicationPath;return string.IsNullOrEmpty(p)||p=="/"?"/":p.TrimEnd('/')+"/"; }
        private static string CookieName(HttpContext ctx)
        { return "IISReportsV3_"+BitConverter.ToString(Hashing.Text(AppPath(ctx)),0,6).Replace("-",""); }
        private static string RandomNonce()
        { byte[] b=new byte[32];using(var rng=RandomNumberGenerator.Create())rng.GetBytes(b);return Convert.ToBase64String(b); }
        private static bool NonceValid(string s)
        {try{return s!=null&&s.Length<=64&&Convert.FromBase64String(s).Length==32;}catch{return false;}}
        private static string ExpectedOrigin(HttpContext ctx)
        {
            string explicitOrigin=Settings.Get("IISReportsPublicOrigin","");
            Uri uri;
            if(explicitOrigin.Length>0)
            {
                if(!Uri.TryCreate(explicitOrigin,UriKind.Absolute,out uri)||(uri.Scheme!="http"&&uri.Scheme!="https")||!string.IsNullOrEmpty(uri.UserInfo)||uri.AbsolutePath!="/"||!string.IsNullOrEmpty(uri.Query)||!string.IsNullOrEmpty(uri.Fragment))
                    throw new ApiFailure(500,"origin_configuration_invalid","IISReportsPublicOrigin must be an exact scheme://host:port origin.");
            }
            else uri=ctx.Request.Url;
            return uri.GetLeftPart(UriPartial.Authority).ToLowerInvariant();
        }
        public static bool SameOrigin(string raw,string expected)
        {
            Uri uri,other;
            if(string.IsNullOrWhiteSpace(raw)||!Uri.TryCreate(raw,UriKind.Absolute,out uri)||!Uri.TryCreate(expected,UriKind.Absolute,out other)||uri.UserInfo.Length>0)return false;
            return (uri.Scheme=="http"||uri.Scheme=="https")&&string.Equals(uri.Scheme,other.Scheme,StringComparison.OrdinalIgnoreCase)&&
                string.Equals(uri.IdnHost,other.IdnHost,StringComparison.OrdinalIgnoreCase)&&uri.Port==other.Port;
        }
        public static string Token(HttpContext ctx)
        {
            RequireRead(ctx);string name=CookieName(ctx);var existing=ctx.Request.Cookies[name];string nonce=existing==null?null:existing.Value;
            if(!NonceValid(nonce))
            {
                nonce=RandomNonce();var cookie=new HttpCookie(name,nonce){HttpOnly=true,Secure=ctx.Request.IsSecureConnection||ExpectedOrigin(ctx).StartsWith("https://",StringComparison.OrdinalIgnoreCase),Path=AppPath(ctx),SameSite=SameSiteMode.Strict};
                ctx.Response.Cookies.Set(cookie);
            }
            string payload=Settings.Json(new {v=1,sub=Subject(ctx),browser=nonce,app=AppPath(ctx),origin=ExpectedOrigin(ctx),expires=DateTime.UtcNow.AddHours(1).Ticks});
            return Convert.ToBase64String(MachineKey.Protect(Encoding.UTF8.GetBytes(payload),"IISReports.V3.CSRF.v1"));
        }
        public static void RequirePost(HttpContext ctx)
        {
            RequireEditor(ctx);
            if(!string.Equals(ctx.Request.HttpMethod,"POST",StringComparison.OrdinalIgnoreCase))
            {ctx.Response.AddHeader("Allow","POST");throw new ApiFailure(405,"post_required","Use POST for state changes.");}
            string origin=ctx.Request.Headers["Origin"];
            if(string.IsNullOrEmpty(origin))origin=ctx.Request.UrlReferrer==null?"":ctx.Request.UrlReferrer.ToString();
            if(!SameOrigin(origin,ExpectedOrigin(ctx)))throw new ApiFailure(403,"csrf_origin","Origin/Referer does not match this app. Check IISReportsPublicOrigin when using a reverse proxy.");
            string token=ctx.Request.Headers["X-IISReports-CSRF"];var cookie=ctx.Request.Cookies[CookieName(ctx)];
            if(string.IsNullOrEmpty(token)||token.Length>8192||cookie==null||!NonceValid(cookie.Value))throw new ApiFailure(403,"csrf_missing","CSRF header or browser cookie missing. Request a fresh token from action=csrf.");
            Dictionary<string,object> data;
            try
            {
                byte[] clear=MachineKey.Unprotect(Convert.FromBase64String(token),"IISReports.V3.CSRF.v1");
                data=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(Encoding.UTF8.GetString(clear));
            }
            catch {throw new ApiFailure(403,"csrf_invalid","CSRF token cannot be verified. Refresh the token; do not disable CSRF protection.");}
            object expires,subject,browser,app,issuedOrigin;
            if(data==null||!data.TryGetValue("expires",out expires)||!data.TryGetValue("sub",out subject)||!data.TryGetValue("browser",out browser)||!data.TryGetValue("app",out app)||!data.TryGetValue("origin",out issuedOrigin))
                throw new ApiFailure(403,"csrf_invalid","Incomplete CSRF token.");
            long ticks; if(!long.TryParse(Convert.ToString(expires,System.Globalization.CultureInfo.InvariantCulture),out ticks))throw new ApiFailure(403,"csrf_invalid","Invalid CSRF expiry.");
            if(ticks<DateTime.UtcNow.Ticks)throw new ApiFailure(403,"csrf_expired","CSRF token expired. Request a fresh token.");
            if(Store.Str(subject)!=Subject(ctx)||Store.Str(app)!=AppPath(ctx)||Store.Str(issuedOrigin)!=ExpectedOrigin(ctx)||
                !Hashing.Equal(Encoding.UTF8.GetBytes(Store.Str(browser)),Encoding.UTF8.GetBytes(cookie.Value)))
                throw new ApiFailure(403,"csrf_invalid","CSRF token belongs to a different Windows user, browser, application or origin.");
        }
        public static void ResponseHeaders(HttpContext ctx)
        {
            ctx.Response.TrySkipIisCustomErrors=true;ctx.Response.SuppressFormsAuthenticationRedirect=true;
            ctx.Response.Cache.SetCacheability(HttpCacheability.NoCache);ctx.Response.Cache.SetNoStore();
            ctx.Response.Headers["X-Content-Type-Options"]="nosniff";ctx.Response.Headers["X-Frame-Options"]="DENY";
            ctx.Response.Headers["Referrer-Policy"]="same-origin";
        }
    }
}
