<%@ WebHandler Language="C#" Class="ReportsHandler" %>
using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;
using IISReports;
using IISReports.V3;
public class ReportsHandler : IHttpHandler
{
    // Mutable response models: anonymous-type properties cannot be assigned later.
    public sealed class ClientRow
    {
        public string clientIp { get; set; }
        public string countryCode { get; set; }
        public int requests { get; set; }
        public DateTime lastSeen { get; set; }
        public string[] users { get; set; }
        public int topStatus { get; set; }
    }
    public sealed class IpRow
    {
        public string clientIp { get; set; }
        public string countryCode { get; set; }
        public int requests { get; set; }
        public DateTime lastSeen { get; set; }
        public string topPath { get; set; }
        public string userAgent { get; set; }
    }
    public sealed class SensitiveRow
    {
        public string pattern { get; set; }
        public long requests { get; set; }
        public int uniqueIps { get; set; }
        public DateTime lastSeen { get; set; }
        public object topIps { get; set; }
    }

    public bool IsReusable { get { return true; } }


    private static void WriteJson(HttpResponse response,object data)
    {
        response.ContentEncoding=Encoding.UTF8;
        response.ContentType="application/json; charset=utf-8";
        response.Write(new JavaScriptSerializer{MaxJsonLength=16*1024*1024}.Serialize(data));
    }
    private static int GetInt(HttpRequest request,string key,int fallback)
    {int n;return int.TryParse(request[key],out n)?Math.Max(1,Math.Min(500,n)):fallback;}
    public void ProcessRequest(HttpContext ctx)
    {
        AccessControl.ResponseHeaders(ctx);
        string action=(ctx.Request.QueryString["action"]??"").Trim();
        try
        {
            if(V3Api.Handles(action)){WriteJson(ctx.Response,V3Api.Run(ctx,action));return;}
            AccessControl.RequireRead(ctx);
            if(ctx.Request.HttpMethod!="GET")throw new ApiFailure(405,"get_required","Use GET for read-only reports.");
            if(action.Length==0){ServeHtml(ctx);return;}
            Db.EnsureSchema();SiteNames.LoadIfChanged();GeoIp.LoadIfChanged();AsnLookup.Reload();
            var req=ctx.Request;object result;
            switch(action)
            {
                case "overview":result=GetOverview(req);break;
                case "timeline":result=GetTimeline(req);break;
                case "clients":result=GetTopClients(req,GetInt(req,"top",30));break;
                case "users":result=GetTopUsers(req,GetInt(req,"top",30));break;
                case "targets":result=GetTopTargets(req,GetInt(req,"top",30));break;
                case "status-codes":result=GetStatusCodes(req);break;
                case "methods":result=GetMethods(req);break;
                case "user-agents":result=GetUserAgentTypes(req,GetInt(req,"top",30));break;
                case "referers":result=GetTopReferers(req,GetInt(req,"top",30));break;
                case "response-times":result=GetResponseTimes(req);break;
                case "sites":result=GetSites();break;
                case "slow-requests":result=GetSlowRequests(req,GetInt(req,"top",30));break;
                case "slow-urls":result=GetSlowUrls(req,GetInt(req,"top",30));break;
                case "security":result=GetSecurity(req);break;
                case "errors-5xx-by-url":result=Get5xxByUrl(req,GetInt(req,"top",30));break;
                case "logs":result=GetLogsPage(req);break;
                case "export":ExportCsv(ctx,req);return;
                case "error-diagnostics":result=ExtraReports.Errors(req);break;
                case "performance":result=ExtraReports.Performance(req);break;
                case "comparison":result=ExtraReports.Comparison(req);break;
                case "bots":result=ExtraReports.Bots(req);break;
                case "asn-info":result=new {ranges=AsnLookup.Count,info=AsnLookup.Info(req["ip"])};break;
                default:throw new ApiFailure(404,"unknown_action","Unknown API action.");
            }
            WriteJson(ctx.Response,result);
        }
        catch(ApiFailure ex)
        {ctx.Response.StatusCode=ex.Status;WriteJson(ctx.Response,new{error=ex.Message,code=ex.Code,security=ex.Status==401||ex.Status==403?AccessControl.IdentityInfo(ctx):null});}
        catch(Exception ex)
        {
            string id=Guid.NewGuid().ToString("N");System.Diagnostics.Trace.TraceError("IISReports v3 "+id+": "+ex);
            ctx.Response.StatusCode=500;WriteJson(ctx.Response,new{error=AccessControl.CanEdit(ctx)?ex.Message:"Request failed. Ask an operator to inspect the server diagnostics.",code="server_error",correlationId=id});
        }
    }
    private static void ServeHtml(HttpContext ctx)
    {
        var res = ctx.Response;
        res.ContentEncoding = Encoding.UTF8;
        res.ContentType = "text/html; charset=utf-8";
        var local = ctx.Server.MapPath("~/index.html");
        if (File.Exists(local))
        {
            res.Write(File.ReadAllText(local, Encoding.UTF8));
            return;
        }
        res.Write("<!DOCTYPE html><html><head><meta charset='utf-8'><title>IIS Reports</title></head><body>");
        res.Write("<h1>API is running</h1>");
        res.Write("<p>Put <b>index.html</b> next to Reports.ashx to open dashboard.</p>");
        res.Write("<p>Check: <a href='?action=overview'>?action=overview</a></p>");
        res.Write("<p>Diag:  <a href='?action=diag'>?action=diag</a></p>");
        res.Write("<p>Health: <a href='?action=health'>?action=health</a></p>");
        res.Write("</body></html>");
    }

    // ====== OVERVIEW ======
    private object GetOverview(HttpRequest req)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT COUNT(*),
       COUNT(DISTINCT ClientIp),
       COUNT(DISTINCT CASE WHEN UserName <> 'Anonymous' THEN UserName END),
       COUNT(DISTINCT CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem ELSE UriStem+'?'+UriQuery END),
       SUM(CASE WHEN Status >= 200 AND Status < 300 THEN 1 ELSE 0 END),
       SUM(CASE WHEN Status >= 300 AND Status < 400 THEN 1 ELSE 0 END),
       SUM(CASE WHEN Status >= 400 AND Status < 500 THEN 1 ELSE 0 END),
       SUM(CASE WHEN Status >= 500 AND Status < 600 THEN 1 ELSE 0 END),
       MIN(Ts), MAX(Ts),
       AVG(CAST(TimeMs AS FLOAT))
FROM ir3.CurrentRequests";
            f.Apply(cmd);

            using (var r = cmd.ExecuteReader())
            {
                if (!r.Read() || r.IsDBNull(0) || r.GetInt32(0) == 0)
                    return new
                    {
                        total = 0, uniqueIps = 0, uniqueUsers = 0, uniqueTargets = 0,
                        status2xx = 0, status3xx = 0, status4xx = 0, status5xx = 0,
                        firstSeen = (DateTime?)null, lastSeen = (DateTime?)null,
                        lastParsed = Store.LastImport(), avgTimeMs = 0.0
                    };

                return new
                {
                    total = r.GetInt32(0),
                    uniqueIps = r.IsDBNull(1) ? 0 : r.GetInt32(1),
                    uniqueUsers = r.IsDBNull(2) ? 0 : r.GetInt32(2),
                    uniqueTargets = r.IsDBNull(3) ? 0 : r.GetInt32(3),
                    status2xx = r.IsDBNull(4) ? 0 : r.GetInt32(4),
                    status3xx = r.IsDBNull(5) ? 0 : r.GetInt32(5),
                    status4xx = r.IsDBNull(6) ? 0 : r.GetInt32(6),
                    status5xx = r.IsDBNull(7) ? 0 : r.GetInt32(7),
                    firstSeen = r.IsDBNull(8) ? (DateTime?)null : DateTime.SpecifyKind(r.GetDateTime(8), DateTimeKind.Utc),
                    lastSeen  = r.IsDBNull(9) ? (DateTime?)null : DateTime.SpecifyKind(r.GetDateTime(9), DateTimeKind.Utc),
                    lastParsed = Store.LastImport(),
                    avgTimeMs = r.IsDBNull(10) ? 0.0 : Math.Round(r.GetDouble(10), 1)
                };
            }
        }
    }

    // ====== TIMELINE ======
    private object GetTimeline(HttpRequest req)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var byHour = new int[24];
        var byDay = new List<object>();

        using (var c = Db.Open())
        {
            using (var cmd = c.CreateCommand())
            {
                cmd.CommandText = "SELECT DATEPART(HOUR, Ts) AS H, COUNT(*) FROM ir3.CurrentRequests";
                f.Apply(cmd);
                cmd.CommandText += " GROUP BY DATEPART(HOUR, Ts)";
                using (var r = cmd.ExecuteReader())
                    while (r.Read())
                    {
                        int h = r.GetInt32(0);
                        if (h >= 0 && h < 24) byHour[h] = r.GetInt32(1);
                    }
            }
            using (var cmd = c.CreateCommand())
            {
                cmd.CommandText = "SELECT CONVERT(varchar(10), Ts, 120) AS D, COUNT(*) FROM ir3.CurrentRequests";
                f.Apply(cmd);
                cmd.CommandText += " GROUP BY CONVERT(varchar(10), Ts, 120) ORDER BY D";
                using (var r = cmd.ExecuteReader())
                    while (r.Read())
                        byDay.Add(new { date = r.GetString(0), count = r.GetInt32(1) });
            }
        }

        return new
        {
            byHour = Enumerable.Range(0, 24).Select(h => new { hour = h, count = byHour[h] }).ToArray(),
            byDay = byDay
        };
    }

    // ====== TOP CLIENTS ======
    private object GetTopClients(HttpRequest req, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var list = new List<ClientRow>();

        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT TOP (@top) ClientIp, COUNT(*) AS Cnt, MAX(Ts)
FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " GROUP BY ClientIp ORDER BY Cnt DESC";
            cmd.Parameters.AddWithValue("@top", top);

            using (var r = cmd.ExecuteReader())
            {
                while (r.Read())
                {
                    var ip = r.GetString(0);
                    list.Add(new ClientRow
                    {
                        clientIp = ip,
                        countryCode = GeoIp.CountryCode(ip),
                        requests = r.GetInt32(1),
                        lastSeen = DateTime.SpecifyKind(r.GetDateTime(2), DateTimeKind.Utc),
                        users = new string[0],
                        topStatus = 0
                    });
                }
            }
        }

        // Догрузка users/topStatus для top N
        using (var c = Db.Open())
        {
            foreach (var item in list)
            {
                using (var cmd = c.CreateCommand())
                {
                    cmd.CommandText = "SELECT TOP 3 UserName FROM ir3.CurrentRequests";
                    f.Apply(cmd);
                    string filterSql = cmd.CommandText.Substring(cmd.CommandText.IndexOf(" WHERE "));
                    cmd.CommandText += " AND ClientIp=@detailIp AND UserName <> 'Anonymous' GROUP BY UserName ORDER BY COUNT(*) DESC;";
                    cmd.CommandText += "SELECT TOP 1 Status FROM ir3.CurrentRequests" + filterSql +
                        " AND ClientIp=@detailIp GROUP BY Status ORDER BY COUNT(*) DESC;";
                    cmd.Parameters.AddWithValue("@detailIp", item.clientIp);
                    using (var r = cmd.ExecuteReader())
                    {
                        var users = new List<string>();
                        while (r.Read()) users.Add(r.GetString(0));
                        item.users = users.ToArray();
                        if (r.NextResult() && r.Read()) item.topStatus = r.GetInt32(0);
                    }
                }
            }
        }

        return list;
    }

    // ====== TOP USERS ======
    private object GetTopUsers(HttpRequest req, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT TOP (@top) UserName, COUNT(*), COUNT(DISTINCT ClientIp), MAX(Ts)
FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " AND UserName <> 'Anonymous' GROUP BY UserName ORDER BY COUNT(*) DESC";
            cmd.Parameters.AddWithValue("@top", top);

            // Apply добавляет WHERE, но если фильтров не было — надо начать с WHERE
            var sql = cmd.CommandText;
            if (!sql.Contains("WHERE")) sql = sql.Replace("FROM ir3.CurrentRequests AND UserName <> 'Anonymous'",
                                                          "FROM ir3.CurrentRequests WHERE UserName <> 'Anonymous'");
            cmd.CommandText = sql;

            var list = new List<object>();
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                    list.Add(new
                    {
                        userName = r.GetString(0),
                        requests = r.GetInt32(1),
                        clients  = r.GetInt32(2),
                        lastSeen = DateTime.SpecifyKind(r.GetDateTime(3), DateTimeKind.Utc)
                    });
            return list;
        }
    }

    // ====== TOP TARGETS ======
    private object GetTopTargets(HttpRequest req, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var list = new List<object>();

        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT TOP (@top)
    Target, COUNT(*) AS Requests,
    COUNT(DISTINCT ClientIp) AS Clients,
    SUM(CASE WHEN Status >= 400 THEN 1 ELSE 0 END) AS Errors
FROM (
    SELECT CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem ELSE UriStem+'?'+UriQuery END AS Target,
           ClientIp, Status, Ts, SiteId, UserName, Method, UserAgent, Referer
    FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += ") t GROUP BY Target ORDER BY Requests DESC";
            cmd.Parameters.AddWithValue("@top", top);

            using (var r = cmd.ExecuteReader())
                while (r.Read())
                    list.Add(new
                    {
                        target = r.GetString(0),
                        requests = r.GetInt32(1),
                        clients = r.GetInt32(2),
                        errors = r.GetInt32(3)
                    });
            return list;
        }
    }

    // ====== STATUS CODES ======
    private object GetStatusCodes(HttpRequest req)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = "SELECT Status, COUNT(*) FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " GROUP BY Status ORDER BY Status";

            long total = 0;
            var items = new List<Tuple<int, int>>();
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    items.Add(Tuple.Create(r.GetInt32(0), r.GetInt32(1)));
                    total += r.GetInt32(1);
                }

            if (total == 0) total = 1;

            return items.Select(t => new
            {
                status = t.Item1,
                category = StatusCat(t.Item1),
                count = t.Item2,
                percent = Math.Round(100.0 * t.Item2 / total, 2)
            }).ToArray();
        }
    }

    // ====== METHODS ======
    private object GetMethods(HttpRequest req)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = "SELECT Method, COUNT(*) FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " GROUP BY Method ORDER BY COUNT(*) DESC";
            var list = new List<object>();
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                    list.Add(new { method = r.GetString(0), count = r.GetInt32(1) });
            return list;
        }
    }

    // ====== USER-AGENT TYPES ======
    private object GetUserAgentTypes(HttpRequest req, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var groups = new Dictionary<string, int>();
        long total = 0;

        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = "SELECT UserAgent, COUNT(*) FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " GROUP BY UserAgent";
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    var ua = r.IsDBNull(0) ? "-" : r.GetString(0);
                    var n = r.GetInt32(1);
                    total += n;
                    var key = ClassifyUa(ua);
                    int cur;
                    groups.TryGetValue(key, out cur);
                    groups[key] = cur + n;
                }
        }
        if (total == 0) total = 1;
        return groups.OrderByDescending(kv => kv.Value).Take(top)
            .Select(kv => new
            {
                type = kv.Key,
                count = kv.Value,
                percent = Math.Round(100.0 * kv.Value / total, 2)
            }).ToArray();
    }

    // ====== REFERERS ======
    private object GetTopReferers(HttpRequest req, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT TOP (@top) Referer, COUNT(*)
FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " AND Referer IS NOT NULL AND Referer <> '-' GROUP BY Referer ORDER BY COUNT(*) DESC";
            var sql = cmd.CommandText;
            if (!sql.Contains("WHERE")) sql = sql.Replace("FROM ir3.CurrentRequests AND ", "FROM ir3.CurrentRequests WHERE ");
            cmd.CommandText = sql;
            cmd.Parameters.AddWithValue("@top", top);

            var list = new List<object>();
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                    list.Add(new { referer = r.GetString(0), count = r.GetInt32(1) });
            return list;
        }
    }

    // ====== RESPONSE TIMES ======
    private object GetResponseTimes(HttpRequest req)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT COUNT(*), AVG(CAST(TimeMs AS FLOAT)),
    SUM(CASE WHEN TimeMs < 50 THEN 1 ELSE 0 END),
    SUM(CASE WHEN TimeMs >= 50 AND TimeMs < 200 THEN 1 ELSE 0 END),
    SUM(CASE WHEN TimeMs >= 200 AND TimeMs < 500 THEN 1 ELSE 0 END),
    SUM(CASE WHEN TimeMs >= 500 AND TimeMs < 1000 THEN 1 ELSE 0 END),
    SUM(CASE WHEN TimeMs >= 1000 AND TimeMs < 3000 THEN 1 ELSE 0 END),
    SUM(CASE WHEN TimeMs >= 3000 THEN 1 ELSE 0 END),
    MAX(TimeMs)
FROM ir3.CurrentRequests";
            f.Apply(cmd);

            int total = 0; double avg = 0;
            long b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, mx = 0;
            using (var r = cmd.ExecuteReader())
            {
                if (r.Read() && !r.IsDBNull(0))
                {
                    total = r.GetInt32(0);
                    avg   = r.IsDBNull(1) ? 0 : r.GetDouble(1);
                    b1 = r.IsDBNull(2) ? 0 : Convert.ToInt64(r.GetInt32(2));
                    b2 = r.IsDBNull(3) ? 0 : Convert.ToInt64(r.GetInt32(3));
                    b3 = r.IsDBNull(4) ? 0 : Convert.ToInt64(r.GetInt32(4));
                    b4 = r.IsDBNull(5) ? 0 : Convert.ToInt64(r.GetInt32(5));
                    b5 = r.IsDBNull(6) ? 0 : Convert.ToInt64(r.GetInt32(6));
                    b6 = r.IsDBNull(7) ? 0 : Convert.ToInt64(r.GetInt32(7));
                    mx = r.IsDBNull(8) ? 0 : r.GetInt64(8);
                }
            }

            double p50 = 0, p90 = 0, p95 = 0, p99 = 0;
            if (total > 0)
            {
                using (var cmd2 = c.CreateCommand())
                {
                    cmd2.CommandText = @"
SELECT DISTINCT
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY TimeMs) OVER (),
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY TimeMs) OVER (),
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TimeMs) OVER (),
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY TimeMs) OVER ()
FROM ir3.CurrentRequests";
                    f.Apply(cmd2);
                    using (var r = cmd2.ExecuteReader())
                        if (r.Read())
                        {
                            p50 = r.IsDBNull(0) ? 0 : Math.Round(r.GetDouble(0), 2);
                            p90 = r.IsDBNull(1) ? 0 : Math.Round(r.GetDouble(1), 2);
                            p95 = r.IsDBNull(2) ? 0 : Math.Round(r.GetDouble(2), 2);
                            p99 = r.IsDBNull(3) ? 0 : Math.Round(r.GetDouble(3), 2);
                        }
                }
            }

            return new
            {
                avg = Math.Round(avg, 1),
                p50 = p50, p90 = p90, p95 = p95, p99 = p99,
                max = mx,
                histogram = new[]
                {
                    new { label = "lt50ms", count = b1 },
                    new { label = "50-200ms", count = b2 },
                    new { label = "200-500ms", count = b3 },
                    new { label = "500ms-1s", count = b4 },
                    new { label = "1-3s", count = b5 },
                    new { label = "gt3s", count = b6 }
                }
            };
        }
    }

    // ====== SITES ======
    private object GetSites()
    {
        var counts = new Dictionary<int, int>();
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = "SELECT SiteId, COUNT(*) FROM ir3.CurrentRequests GROUP BY SiteId";
            using (var r = cmd.ExecuteReader())
                while (r.Read()) counts[r.GetInt32(0)] = r.GetInt32(1);
        }
        var all = new HashSet<int>(counts.Keys);
        foreach (var id in SiteNames.All.Keys) all.Add(id);
        using(var c=Db.Open())using(var cmd=c.CreateCommand())
        {
            cmd.CommandText="SELECT DISTINCT SiteId FROM ir3.Sources";
            using(var reader=cmd.ExecuteReader())while(reader.Read())all.Add(reader.GetInt32(0));
        }
        return all.OrderBy(id => id)
            .Select(id => new
            {
                siteId = id,
                name = SiteNames.Get(id),
                requests = counts.ContainsKey(id) ? counts[id] : 0
            }).ToArray();
    }

    // ====== SLOW REQUESTS ======
    private object GetSlowRequests(HttpRequest req, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var list = new List<object>();
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT TOP (@top) Ts, SiteId, ClientIp, Method,
    CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem ELSE UriStem+'?'+UriQuery END AS Target,
    Status, TimeMs, UserAgent
FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " ORDER BY TimeMs DESC";
            cmd.Parameters.AddWithValue("@top", top);

            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    var ip = r.IsDBNull(2) ? "-" : r.GetString(2);
                    list.Add(new
                    {
                        timestamp = DateTime.SpecifyKind(r.GetDateTime(0), DateTimeKind.Utc),
                        siteId = r.GetInt32(1),
                        siteName = SiteNames.Get(r.GetInt32(1)),
                        clientIp = ip,
                        countryCode = GeoIp.CountryCode(ip),
                        method = r.IsDBNull(3) ? "-" : r.GetString(3),
                        target = r.IsDBNull(4) ? "-" : r.GetString(4),
                        status = r.IsDBNull(5) ? 0 : r.GetInt32(5),
                        timeMs = r.IsDBNull(6) ? 0 : r.GetInt64(6),
                        userAgent = r.IsDBNull(7) ? "-" : r.GetString(7)
                    });
                }
            return list;
        }
    }

    // ====== SLOW URLS (percentiles) ======
    private object GetSlowUrls(HttpRequest req, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var list = new List<object>();
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
;WITH t AS (
    SELECT CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem ELSE UriStem+'?'+UriQuery END AS Target,
           TimeMs, Status
    FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += @"
), p AS (
    SELECT Target, TimeMs, Status,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY TimeMs) OVER (PARTITION BY Target) AS P50,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TimeMs) OVER (PARTITION BY Target) AS P95,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY TimeMs) OVER (PARTITION BY Target) AS P99
    FROM t
)
SELECT TOP (@top) Target, COUNT(*) AS Requests,
    SUM(CASE WHEN Status >= 400 THEN 1 ELSE 0 END) AS Errors,
    AVG(CAST(TimeMs AS FLOAT)) AS AvgMs,
    MAX(P50), MAX(P95), MAX(P99), MAX(TimeMs)
FROM p GROUP BY Target HAVING COUNT(*) >= 2
ORDER BY MAX(P95) DESC, Target";
            cmd.Parameters.AddWithValue("@top", top);

            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    list.Add(new
                    {
                        target = r.GetString(0),
                        requests = r.GetInt32(1),
                        errors = r.GetInt32(2),
                        avg = Math.Round(r.IsDBNull(3) ? 0 : r.GetDouble(3), 1),
                        p50 = r.IsDBNull(4) ? 0 : Math.Round(r.GetDouble(4), 2),
                        p95 = r.IsDBNull(5) ? 0 : Math.Round(r.GetDouble(5), 2),
                        p99 = r.IsDBNull(6) ? 0 : Math.Round(r.GetDouble(6), 2),
                        max = r.IsDBNull(7) ? 0 : r.GetInt64(7)
                    });
                }
            return list;
        }
    }

    // ====== 5xx BY URL ======
    private object Get5xxByUrl(HttpRequest req, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var list = new List<object>();
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @";WITH baseRows AS (
SELECT CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem
            ELSE UriStem+'?'+UriQuery END AS Target, ClientIp, Status, Ts
FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += @"
), failed AS (SELECT * FROM baseRows WHERE Status >= 500 AND Status < 600)
SELECT TOP (@top) b.Target, COUNT(*), COUNT(DISTINCT b.ClientIp), COUNT(*),
    MIN(b.Ts), MAX(b.Ts),
    STUFF((SELECT DISTINCT ',' + CONVERT(varchar(4), d.Status)
           FROM failed d WHERE d.Target=b.Target FOR XML PATH('')),1,1,'')
FROM failed b GROUP BY b.Target ORDER BY COUNT(*) DESC, b.Target";
            cmd.Parameters.AddWithValue("@top", top);
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                    list.Add(new
                    {
                        target = r.IsDBNull(0) ? "-" : r.GetString(0),
                        requests = r.GetInt32(1), clients = r.GetInt32(2), errors = r.GetInt32(3),
                        firstSeen = DateTime.SpecifyKind(r.GetDateTime(4), DateTimeKind.Utc), lastSeen = DateTime.SpecifyKind(r.GetDateTime(5), DateTimeKind.Utc),
                        statuses = r.IsDBNull(6) ? "" : r.GetString(6)
                    });
            return list;
        }
    }

    private object GetSecurity(HttpRequest req)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        int top = 20;

        var top4xx = QueryTopIps(req, "Status >= 400 AND Status < 500", top);
        var topAuth = QueryTopIps(req, "(Status = 401 OR Status = 403)", top);

        // Sensitive paths
        string[] patterns = {
            ".env", ".git/", ".svn/", ".aws/", ".ssh/", ".docker/", ".htaccess",
            "wp-admin", "wp-login", "wp-config", "xmlrpc.php", "adminer", "phpmyadmin",
            "actuator", "heapdump", "autodiscover", "/owa/", "ecp/", "ews/",
            "cgi-bin/", "server-status", "WEB-INF", "manager/html", "jenkins"
        };

        var sensitive = new List<SensitiveRow>();
        using (var c = Db.Open())
        {
            foreach (var p in patterns)
            {
                var f2 = LogService.QueryFilters.FromRequest(req);
                using (var cmd = c.CreateCommand())
                {
                    cmd.CommandText = @"
SELECT COUNT(*), COUNT(DISTINCT ClientIp), MAX(Ts)
FROM ir3.CurrentRequests";
                    f2.Apply(cmd);
                    cmd.CommandText += " AND UriStem LIKE @p";
                    var sql = cmd.CommandText;
                    if (!sql.Contains("WHERE")) sql = sql.Replace("FROM ir3.CurrentRequests AND ", "FROM ir3.CurrentRequests WHERE ");
                    cmd.CommandText = sql;
                    cmd.Parameters.AddWithValue("@p", "%" + p + "%");

                    long cnt = 0; int uniq = 0; DateTime last = DateTime.MinValue;
                    using (var r = cmd.ExecuteReader())
                        if (r.Read())
                        {
                            cnt = r.IsDBNull(0) ? 0 : r.GetInt32(0);
                            uniq = r.IsDBNull(1) ? 0 : r.GetInt32(1);
                            last = r.IsDBNull(2) ? DateTime.MinValue : DateTime.SpecifyKind(r.GetDateTime(2), DateTimeKind.Utc);
                        }
                    if (cnt == 0) continue;

                    var topIps = QueryTopIpsForPath(req, p, 3);
                    sensitive.Add(new SensitiveRow
                    {
                        pattern = p,
                        requests = cnt,
                        uniqueIps = uniq,
                        lastSeen = last,
                        topIps = topIps
                    });
                }
            }
        }
        sensitive = sensitive.OrderByDescending(x => x.requests).Take(30).ToList();

        // Suspicious UAs
        string[] uaMarks = { "curl", "wget", "python-requests", "python-urllib", "zgrab", "nmap",
                             "masscan", "nikto", "sqlmap", "nuclei", "acunetix", "dirbuster",
                             "gobuster", "hydra", "metasploit", "fuzz" };
        var suspicious = new List<IpRow>();
        using (var c = Db.Open())
        {
            foreach (var m in uaMarks)
            {
                var f2 = LogService.QueryFilters.FromRequest(req);
                using (var cmd = c.CreateCommand())
                {
                    cmd.CommandText = @"
SELECT TOP 5 ClientIp, COUNT(*) AS Cnt, MAX(Ts), MAX(UserAgent)
FROM ir3.CurrentRequests";
                    f2.Apply(cmd);
                    cmd.CommandText += " AND UserAgent LIKE @uaPattern GROUP BY ClientIp ORDER BY Cnt DESC";
                    var sql = cmd.CommandText;
                    if (!sql.Contains("WHERE")) sql = sql.Replace("FROM ir3.CurrentRequests AND ", "FROM ir3.CurrentRequests WHERE ");
                    cmd.CommandText = sql;
                    cmd.Parameters.AddWithValue("@uaPattern", "%" + m + "%");

                    using (var r = cmd.ExecuteReader())
                        while (r.Read())
                        {
                            var ip = r.GetString(0);
                            suspicious.Add(new IpRow
                            {
                                clientIp = ip,
                                countryCode = GeoIp.CountryCode(ip),
                                requests = r.GetInt32(1),
                                lastSeen = DateTime.SpecifyKind(r.GetDateTime(2), DateTimeKind.Utc),
                                userAgent = r.IsDBNull(3) ? "-" : r.GetString(3),
                                topPath = ""
                            });
                        }
                }
            }
        }

        return new
        {
            top4xx = top4xx,
            topAuth = topAuth,
            sensitivePaths = sensitive,
            suspiciousUa = suspicious.OrderByDescending(x => x.requests).Take(top).ToArray()
        };
    }

    private object QueryTopIps(HttpRequest req, string statusWhere, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var list = new List<IpRow>();
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT TOP (@top) ClientIp, COUNT(*) AS Cnt, MAX(Ts) AS LastSeen
FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " AND " + statusWhere + " GROUP BY ClientIp ORDER BY Cnt DESC";
            var sql = cmd.CommandText;
            if (!sql.Contains("WHERE")) sql = sql.Replace("FROM ir3.CurrentRequests AND ", "FROM ir3.CurrentRequests WHERE ");
            cmd.CommandText = sql;
            cmd.Parameters.AddWithValue("@top", top);

            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    var ip = r.GetString(0);
                    list.Add(new IpRow
                    {
                        clientIp = ip,
                        countryCode = GeoIp.CountryCode(ip),
                        requests = r.GetInt32(1),
                        lastSeen = DateTime.SpecifyKind(r.GetDateTime(2), DateTimeKind.Utc),
                        topPath = ""
                    });
                }
        }
        // top path для каждого
        using (var c = Db.Open())
            foreach (var item in list)
            {
                using (var cmd = c.CreateCommand())
                {
                    const string targetSql = "CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem ELSE UriStem+'?'+UriQuery END";
                    cmd.CommandText = "SELECT TOP 1 " + targetSql + " FROM ir3.CurrentRequests";
                    f.Apply(cmd);
                    cmd.CommandText += " AND ClientIp=@detailIp AND " + statusWhere +
                        " GROUP BY " + targetSql + " ORDER BY COUNT(*) DESC";
                    cmd.Parameters.AddWithValue("@detailIp", item.clientIp);
                    var v = cmd.ExecuteScalar();
                    if (v != null && v != DBNull.Value) item.topPath = (string)v;
                }
            }
        return list;
    }

    private object QueryTopIpsForPath(HttpRequest req, string pattern, int top)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var list = new List<object>();
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT TOP (@top) ClientIp, COUNT(*) AS Cnt
FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " AND UriStem LIKE @p GROUP BY ClientIp ORDER BY Cnt DESC";
            var sql = cmd.CommandText;
            if (!sql.Contains("WHERE")) sql = sql.Replace("FROM ir3.CurrentRequests AND ", "FROM ir3.CurrentRequests WHERE ");
            cmd.CommandText = sql;
            cmd.Parameters.AddWithValue("@top", top);
            cmd.Parameters.AddWithValue("@p", "%" + pattern + "%");

            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    var ip = r.GetString(0);
                    list.Add(new
                    {
                        clientIp = ip,
                        countryCode = GeoIp.CountryCode(ip),
                        requests = r.GetInt32(1)
                    });
                }
        }
        return list;
    }

    // ====== ALERTS ======
    private object GetLogsPage(HttpRequest req)
    {
        int page = 1, pageSize = 100;
        int.TryParse(req["page"], out page);
        if (!int.TryParse(req["pageSize"], out pageSize)) pageSize = 100;
        if (page < 1) page = 1;
        if (pageSize < 1 || pageSize > 500) pageSize = 100;

        var f = LogService.QueryFilters.FromRequest(req);

        int total;
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM ir3.CurrentRequests";
            f.Apply(cmd);
            total = (int)cmd.ExecuteScalar();
        }

        var items = new List<object>();
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT Ts, SiteId, ClientIp, UserName, Method,
    CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem ELSE UriStem+'?'+UriQuery END AS Target,
    Status, SubStatus, TimeMs, UserAgent, Referer, RawEventId, Win32Status
FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " ORDER BY Ts DESC, Id DESC OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY";
            cmd.Parameters.AddWithValue("@skip", ((long)page - 1L) * pageSize);
            cmd.Parameters.AddWithValue("@take", pageSize);

            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    var ip = r.IsDBNull(2) ? "-" : r.GetString(2);
                    var siteId = r.GetInt32(1);
                    items.Add(new
                    {
                        timestamp = DateTime.SpecifyKind(r.GetDateTime(0), DateTimeKind.Utc),
                        siteId = siteId,
                        siteName = SiteNames.Get(siteId),
                        clientIp = ip,
                        countryCode = GeoIp.CountryCode(ip),
                        userName = r.IsDBNull(3) ? "Anonymous" : r.GetString(3),
                        method = r.IsDBNull(4) ? "-" : r.GetString(4),
                        target = r.IsDBNull(5) ? "-" : r.GetString(5),
                        status = r.IsDBNull(6) ? 0 : r.GetInt32(6),
                        subStatus = r.IsDBNull(7) ? 0 : r.GetInt32(7),
                        timeMs = r.IsDBNull(8) ? 0 : r.GetInt64(8),
                        userAgent = r.IsDBNull(9) ? "-" : r.GetString(9),
                        referer = r.IsDBNull(10) ? "-" : r.GetString(10),
                        rawEventId = r.GetInt64(11), win32Status = r.IsDBNull(12) ? 0L : r.GetInt64(12)
                    });
                }
        }

        return new { total = total, page = page, pageSize = pageSize, items = items };
    }

    // ====== EXPORT ======
    private void ExportCsv(HttpContext ctx, HttpRequest req)
    {
        var f = LogService.QueryFilters.FromRequest(req);
        var res = ctx.Response;
        var filename = "iis_logs_" + DateTime.UtcNow.ToString("yyyyMMdd_HHmmss") + ".csv";
        res.ContentType = "text/csv; charset=utf-8";
        res.AddHeader("Content-Disposition", "attachment; filename=\"" + filename + "\"");
        res.ContentEncoding = new UTF8Encoding(false);
        var bom = new byte[] { 0xEF, 0xBB, 0xBF };
        res.OutputStream.Write(bom, 0, bom.Length);

        using (var sw = new StreamWriter(res.OutputStream, new UTF8Encoding(false), 65536, true))
        using (var c = Db.Open())
        using (var cmd = c.CreateCommand())
        {
            cmd.CommandText = @"
SELECT Ts, SiteId, ClientIp, UserName, Method,
    CASE WHEN UriQuery IS NULL OR UriQuery='-' OR UriQuery='' THEN UriStem ELSE UriStem+'?'+UriQuery END AS Target,
    Status, SubStatus, TimeMs, UserAgent, Referer
FROM ir3.CurrentRequests";
            f.Apply(cmd);
            cmd.CommandText += " ORDER BY Ts DESC";
            cmd.CommandTimeout = 600;

            sw.WriteLine("DateTime;SiteId;SiteName;ClientIp;CountryCode;UserName;Method;Target;Status;SubStatus;TimeMs;UserAgent;Referer");
            using (var r = cmd.ExecuteReader())
                while (r.Read())
                {
                    var ip = r.IsDBNull(2) ? "-" : r.GetString(2);
                    var siteId = r.GetInt32(1);
                    sw.Write(DateTime.SpecifyKind(r.GetDateTime(0), DateTimeKind.Utc).ToString("yyyy-MM-dd HH:mm:ss"));
                    sw.Write(';'); sw.Write(siteId);
                    sw.Write(';'); sw.Write(EscapeCsv(SiteNames.Get(siteId)));
                    sw.Write(';'); sw.Write(EscapeCsv(ip));
                    sw.Write(';'); sw.Write(EscapeCsv(GeoIp.CountryCode(ip) ?? ""));
                    sw.Write(';'); sw.Write(EscapeCsv(r.IsDBNull(3) ? "Anonymous" : r.GetString(3)));
                    sw.Write(';'); sw.Write(EscapeCsv(r.IsDBNull(4) ? "-" : r.GetString(4)));
                    sw.Write(';'); sw.Write(EscapeCsv(r.IsDBNull(5) ? "-" : r.GetString(5)));
                    sw.Write(';'); sw.Write(r.IsDBNull(6) ? 0 : r.GetInt32(6));
                    sw.Write(';'); sw.Write(r.IsDBNull(7) ? 0 : r.GetInt32(7));
                    sw.Write(';'); sw.Write(r.IsDBNull(8) ? 0 : r.GetInt64(8));
                    sw.Write(';'); sw.Write(EscapeCsv(r.IsDBNull(9) ? "-" : r.GetString(9)));
                    sw.Write(';'); sw.Write(EscapeCsv(r.IsDBNull(10) ? "-" : r.GetString(10)));
                    sw.WriteLine();
                }
        }
        ctx.ApplicationInstance.CompleteRequest();
    }

    private static string EscapeCsv(string s)
    {
        if (s == null) return "";
        if (s.Length > 0 && (s[0] == '=' || s[0] == '+' || s[0] == '-' || s[0] == '@' || s[0] == '\t' || s[0] == '\r' || s[0] == '\n'))
            s = "'" + s;
        if (s.Contains(";") || s.Contains("\"") || s.Contains("\n") || s.Contains("\r"))
            return "\"" + s.Replace("\"", "\"\"") + "\"";
        return s;
    }

    private static string StatusCat(int c)
    {
        if (c >= 200 && c < 300) return "success";
        if (c >= 300 && c < 400) return "redirect";
        if (c >= 400 && c < 500) return "client-error";
        if (c >= 500 && c < 600) return "server-error";
        return "other";
    }

    private static string ClassifyUa(string ua)
    {
        if (string.IsNullOrWhiteSpace(ua) || ua == "-") return "Unknown";
        if (ua.Contains("Edg/")) return "Edge";
        if (ua.Contains("OPR/") || ua.Contains("Opera")) return "Opera";
        if (ua.Contains("YaBrowser")) return "Yandex";
        if (ua.Contains("Chrome/")) return "Chrome";
        if (ua.Contains("Firefox/")) return "Firefox";
        if (ua.Contains("Safari/")) return "Safari";
        var low = ua.ToLowerInvariant();
        string[] bots = {
            "bot","crawler","spider","googlebot","bingbot","ahrefs",
            "oai-searchbot","gptbot","claudebot","perplexity","curl","wget",
            "python","palo alto","censys","zgrab","nmap","exchangescanner",
            "crusader","bytespider","semrush","yandexbot","recordedfuture"
        };
        foreach (var b in bots) if (low.Contains(b)) return "Bot / Scanner";
        return "Other";
    }
}