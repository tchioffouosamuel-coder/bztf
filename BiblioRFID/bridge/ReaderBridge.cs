using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO.Ports;
using System.Linq;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using GDotnet.Reader.Api.DAL;
using GDotnet.Reader.Api.Protocol.Gx;

namespace BiblioRfid.ReaderBridge
{
    internal sealed class TagResult
    {
        public string Epc { get; set; }
        public string Tid { get; set; }
        public int Rssi { get; set; }
        public int Antenna { get; set; }
    }

    internal sealed class BeepResult
    {
        public bool Accepted { get; set; }
        public int StartCommandMs { get; set; }
        public int HoldMs { get; set; }
        public int StopCommandMs { get; set; }
    }

    internal static class Program
    {
        private const string Marker = "__RFID_JSON__";
        private static readonly object TagsLock = new object();
        private static readonly object OutputLock = new object();
        private static readonly Dictionary<string, TagResult> Tags = new Dictionary<string, TagResult>();
        private static readonly Dictionary<string, DateTime> DaemonLastEmit = new Dictionary<string, DateTime>();
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        private static bool DaemonMode;
        private static GClient DaemonClient;

        private static int Main(string[] args)
        {
            Console.InputEncoding = new UTF8Encoding(false);
            Console.OutputEncoding = new UTF8Encoding(false);
            try
            {
                if (args.Length == 0) return Fail("Commande manquante.");
                switch (args[0].ToLowerInvariant())
                {
                    case "list":
                        return ListDevices();
                    case "probe":
                        return Probe(args);
                    case "scan":
                        return ScanCommand(args);
                    case "write":
                        return WriteCommand(args);
                    case "daemon":
                        return RunDaemon();
                    default:
                        return Fail("Commande inconnue.");
                }
            }
            catch (Exception error)
            {
                return Fail(error.GetBaseException().Message);
            }
        }

        private static int ListDevices()
        {
            List<string> usb = GClient.GetUsbHidList() ?? new List<string>();
            Emit(new { ok = true, usb = usb.ToArray(), serial = SerialPort.GetPortNames() });
            return 0;
        }

        private static int Probe(string[] args)
        {
            if (args.Length < 3) return Fail("Paramètres de connexion manquants.");
            GClient client = null;
            string status;
            try
            {
                client = Open(args[1], args[2], out status);
                Emit(new { ok = true, status = status, reader = client.Name, serialNumber = client.SerialNo });
                return 0;
            }
            finally
            {
                if (client != null) client.Close();
            }
        }

        private static int ScanCommand(string[] args)
        {
            if (args.Length < 3) return Fail("Paramètres de lecture manquants.");
            int timeout = args.Length > 3 ? ClampTimeout(args[3]) : 1600;
            GClient client = null;
            string status;
            try
            {
                client = Open(args[1], args[2], out status);
                Subscribe(client);
                SetComputerControlledBuzzer(client);
                List<TagResult> tags = Scan(client, timeout, null);
                string previousSignature = args.Length > 4 ? args[4] : "";
                HashSet<string> previousTags = new HashSet<string>(
                    previousSignature.Split(new[] { '|' }, StringSplitOptions.RemoveEmptyEntries),
                    StringComparer.OrdinalIgnoreCase);
                bool hasNewTag = tags.Any(tag => !previousTags.Contains(TagKey(tag)));
                bool beeped = hasNewTag && BeepPulse(client).Accepted;
                Emit(new { ok = true, status = status, tags = tags.ToArray(), count = tags.Count, beeped = beeped });
                return 0;
            }
            finally
            {
                if (client != null)
                {
                    Stop(client);
                    client.Close();
                }
            }
        }

        private static int WriteCommand(string[] args)
        {
            if (args.Length < 4) return Fail("Paramètres d'écriture manquants.");
            string epc = (args[3] ?? "").Trim().ToUpperInvariant();
            if (epc.Length == 0 || epc.Length % 4 != 0 || !IsHex(epc))
                return Fail("L'EPC doit être hexadécimal et contenir un nombre entier de mots de 16 bits.");

            GClient client = null;
            string status;
            try
            {
                client = Open(args[1], args[2], out status);
                Subscribe(client);
                SetComputerControlledBuzzer(client);
                List<TagResult> before = Scan(client, 1800, null);
                if (before.Count == 0) return Fail("Aucun tag détecté. Placez un seul livre sur le lecteur.");
                if (before.Count > 1) return Fail("Plusieurs tags détectés. Retirez les autres livres avant l'écriture.");
                TagResult target = before[0];
                if (String.IsNullOrWhiteSpace(target.Tid)) return Fail("Le tag ne fournit pas de TID; l'écriture sécurisée est annulée.");

                Stop(client);
                MsgBaseWriteEpc write = new MsgBaseWriteEpc();
                write.AntennaEnable = 1;
                write.Area = 1;
                write.Start = 1;
                ushort pc = (ushort)((epc.Length / 4) << 11);
                write.HexWriteData = pc.ToString("X4") + epc;
                write.Filter = TidFilter(target.Tid);
                client.SendSynMsg(write, 5000);
                if (write.RtCode != 0) return Fail("Échec d'écriture: " + (write.RtMsg ?? ("code " + write.RtCode)));

                Thread.Sleep(180);
                List<TagResult> after = Scan(client, 1800, target.Tid);
                TagResult verified = after.FirstOrDefault(tag =>
                    String.Equals(tag.Tid, target.Tid, StringComparison.OrdinalIgnoreCase) &&
                    String.Equals(tag.Epc, epc, StringComparison.OrdinalIgnoreCase));
                if (verified == null) return Fail("Écriture envoyée, mais la relecture de contrôle ne correspond pas.");

                bool nativeBeeped = NativeBeep(client).Accepted;
                Emit(new { ok = true, status = status, verified = true, nativeBeeped = nativeBeeped, tag = verified, previousEpc = target.Epc });
                return 0;
            }
            finally
            {
                if (client != null)
                {
                    Stop(client);
                    client.Close();
                }
            }
        }

        private static int RunDaemon()
        {
            DaemonMode = true;
            Emit(new
            {
                type = "ready",
                ok = true,
                buzzerPulseMs = BridgeSettings.BuzzerPulseMilliseconds,
                buzzerMode = BridgeSettings.UseControlledBuzzerPulse ? "controlled" : "native",
                beepRearmMs = BridgeSettings.BeepRearmMilliseconds
            });
            string line;
            while ((line = Console.ReadLine()) != null)
            {
                int id = 0;
                try
                {
                    Dictionary<string, object> command = Json.Deserialize<Dictionary<string, object>>(line);
                    id = command.ContainsKey("id") ? Convert.ToInt32(command["id"]) : 0;
                    string action = GetCommandString(command, "action").ToLowerInvariant();
                    if (action == "connect") DaemonConnect(id, command);
                    else if (action == "disconnect") DaemonDisconnect(id);
                    else if (action == "beep") DaemonBeep(id);
                    else if (action == "write") DaemonWrite(id, command);
                    else if (action == "status") DaemonRespond(id, true, null, new Dictionary<string, object> { { "connected", DaemonClient != null } });
                    else if (action == "shutdown")
                    {
                        DaemonDisconnect(id);
                        break;
                    }
                    else DaemonRespond(id, false, "Commande daemon inconnue.");
                }
                catch (Exception error)
                {
                    DaemonRespond(id, false, error.GetBaseException().Message);
                }
            }
            CloseDaemonClient();
            DaemonMode = false;
            return 0;
        }

        private static void DaemonConnect(int id, Dictionary<string, object> command)
        {
            CloseDaemonClient();
            string status;
            DaemonClient = Open(GetCommandString(command, "connectionType"), GetCommandString(command, "endpoint"), out status);
            Subscribe(DaemonClient);
            Stop(DaemonClient);
            bool buzzerControlled = SetComputerControlledBuzzer(DaemonClient);
            StartContinuousInventory(DaemonClient, null);
            DaemonRespond(id, true, null, new Dictionary<string, object>
            {
                { "status", status },
                { "reader", DaemonClient.Name },
                { "serialNumber", DaemonClient.SerialNo },
                { "buzzerControlled", buzzerControlled },
                { "buzzerMode", BridgeSettings.UseControlledBuzzerPulse ? "controlled" : "native" },
                { "buzzerPulseMs", BridgeSettings.BuzzerPulseMilliseconds },
                { "beepRearmMs", BridgeSettings.BeepRearmMilliseconds }
            });
        }

        private static void DaemonDisconnect(int id)
        {
            CloseDaemonClient();
            DaemonRespond(id, true, null, new Dictionary<string, object> { { "connected", false } });
        }

        private static void DaemonBeep(int id)
        {
            RequireDaemonClient();
            BeepResult pulse = BeepPulse(DaemonClient);
            DaemonRespond(id, pulse.Accepted, pulse.Accepted ? null : "Le buzzer n'a pas accepté la commande.",
                new Dictionary<string, object>
                {
                    { "beeped", pulse.Accepted },
                    { "mode", BridgeSettings.UseControlledBuzzerPulse ? "controlled" : "native" },
                    { "pulseMs", BridgeSettings.BuzzerPulseMilliseconds },
                    { "startCommandMs", pulse.StartCommandMs },
                    { "holdMs", pulse.HoldMs },
                    { "stopCommandMs", pulse.StopCommandMs }
                });
        }

        private static void DaemonWrite(int id, Dictionary<string, object> command)
        {
            RequireDaemonClient();
            string epc = GetCommandString(command, "epc").Trim().ToUpperInvariant();
            string tid = GetCommandString(command, "tid").Trim().ToUpperInvariant();
            if (epc.Length == 0 || epc.Length % 4 != 0 || !IsHex(epc))
                throw new InvalidOperationException("L'EPC doit être hexadécimal et contenir un nombre entier de mots de 16 bits.");
            if (String.IsNullOrWhiteSpace(tid))
                throw new InvalidOperationException("Le TID du tag cible est manquant.");

            TagResult verified = null;
            bool nativeBeeped = false;
            Stop(DaemonClient);
            try
            {
                MsgBaseWriteEpc write = new MsgBaseWriteEpc();
                write.AntennaEnable = 1;
                write.Area = 1;
                write.Start = 1;
                ushort pc = (ushort)((epc.Length / 4) << 11);
                write.HexWriteData = pc.ToString("X4") + epc;
                write.Filter = TidFilter(tid);
                DaemonClient.SendSynMsg(write, 5000);
                if (write.RtCode != 0)
                    throw new InvalidOperationException("Échec d'écriture: " + (write.RtMsg ?? ("code " + write.RtCode)));

                Thread.Sleep(120);
                List<TagResult> after = Scan(DaemonClient, 900, tid);
                verified = after.FirstOrDefault(tag =>
                    String.Equals(tag.Tid, tid, StringComparison.OrdinalIgnoreCase) &&
                    String.Equals(tag.Epc, epc, StringComparison.OrdinalIgnoreCase));
                if (verified == null)
                    throw new InvalidOperationException("Écriture envoyée, mais la relecture de contrôle ne correspond pas.");
                nativeBeeped = NativeBeep(DaemonClient).Accepted;
            }
            finally
            {
                StartContinuousInventory(DaemonClient, null);
            }
            DaemonRespond(id, true, null, new Dictionary<string, object>
            {
                { "verified", true },
                { "nativeBeeped", nativeBeeped },
                { "tag", verified }
            });
        }

        private static void StartContinuousInventory(GClient client, string filterTid)
        {
            MsgBaseInventoryEpc inventory = new MsgBaseInventoryEpc();
            inventory.AntennaEnable = 1;
            inventory.InventoryMode = 1;
            inventory.ReadTid = new ParamEpcReadTid { Mode = 0, Len = 6 };
            if (!String.IsNullOrWhiteSpace(filterTid)) inventory.Filter = TidFilter(filterTid);
            client.SendSynMsg(inventory, 3500);
            if (inventory.RtCode != 0)
                throw new InvalidOperationException("Lecture refusée: " + (inventory.RtMsg ?? ("code " + inventory.RtCode)));
        }

        private static void CloseDaemonClient()
        {
            if (DaemonClient == null) return;
            try { Stop(DaemonClient); } catch { }
            try { DaemonClient.Close(); } catch { }
            DaemonClient = null;
            lock (TagsLock)
            {
                Tags.Clear();
                DaemonLastEmit.Clear();
            }
        }

        private static void RequireDaemonClient()
        {
            if (DaemonClient == null) throw new InvalidOperationException("Le lecteur RFID n'est pas connecté.");
        }

        private static string GetCommandString(Dictionary<string, object> command, string key)
        {
            return command.ContainsKey(key) && command[key] != null ? Convert.ToString(command[key]) : "";
        }

        private static void DaemonRespond(int id, bool ok, string error, Dictionary<string, object> values = null)
        {
            Dictionary<string, object> response = new Dictionary<string, object>
            {
                { "type", "response" },
                { "id", id },
                { "ok", ok }
            };
            if (!String.IsNullOrWhiteSpace(error)) response["error"] = error;
            if (values != null)
            {
                foreach (KeyValuePair<string, object> value in values) response[value.Key] = value.Value;
            }
            Emit(response);
        }

        private static GClient Open(string type, string endpoint, out string statusText)
        {
            GClient client = new GClient();
            eConnectionAttemptEventStatusType status = eConnectionAttemptEventStatusType.OK;
            bool opened;
            switch ((type ?? "").ToLowerInvariant())
            {
                case "usb":
                    if (String.IsNullOrWhiteSpace(endpoint))
                    {
                        List<string> devices = GClient.GetUsbHidList();
                        endpoint = devices != null && devices.Count > 0 ? devices[0] : "";
                    }
                    if (String.IsNullOrWhiteSpace(endpoint)) throw new InvalidOperationException("Aucun lecteur USB HID détecté.");
                    opened = client.OpenUsbHid(endpoint, IntPtr.Zero, 3500, out status);
                    break;
                case "serial":
                    if (String.IsNullOrWhiteSpace(endpoint)) throw new InvalidOperationException("Port série manquant.");
                    opened = client.OpenSerial(endpoint, 3500, out status);
                    break;
                case "tcp":
                    if (String.IsNullOrWhiteSpace(endpoint)) throw new InvalidOperationException("Adresse TCP manquante.");
                    opened = client.OpenTcp(endpoint, 3500, out status);
                    break;
                default:
                    throw new InvalidOperationException("Type de connexion non pris en charge.");
            }
            statusText = status.ToString();
            if (!opened)
            {
                client.Close();
                throw new InvalidOperationException("Connexion refusée par le lecteur (" + status + "). Fermez le logiciel de démonstration constructeur s'il est ouvert.");
            }
            return client;
        }

        private static void Subscribe(GClient client)
        {
            client.OnEncapedTagEpcLog += OnTag;
        }

        private static List<TagResult> Scan(GClient client, int timeout, string filterTid)
        {
            lock (TagsLock) Tags.Clear();
            Stop(client);
            MsgBaseInventoryEpc inventory = new MsgBaseInventoryEpc();
            inventory.AntennaEnable = 1;
            inventory.InventoryMode = 1;
            inventory.ReadTid = new ParamEpcReadTid { Mode = 0, Len = 6 };
            if (!String.IsNullOrWhiteSpace(filterTid)) inventory.Filter = TidFilter(filterTid);
            client.SendSynMsg(inventory, 3500);
            if (inventory.RtCode != 0)
                throw new InvalidOperationException("Lecture refusée: " + (inventory.RtMsg ?? ("code " + inventory.RtCode)));
            Thread.Sleep(timeout);
            Stop(client);
            lock (TagsLock) return Tags.Values.ToList();
        }

        private static void OnTag(EncapedLogBaseEpcInfo message)
        {
            if (message == null || message.logBaseEpcInfo == null || message.logBaseEpcInfo.Result != 0) return;
            LogBaseEpcInfo raw = message.logBaseEpcInfo;
            string epc = (raw.Epc ?? "").Trim().ToUpperInvariant();
            string tid = (raw.Tid ?? "").Trim().ToUpperInvariant();
            string key = String.IsNullOrWhiteSpace(tid) ? epc : tid;
            if (String.IsNullOrWhiteSpace(key)) return;
            TagResult tag = new TagResult { Epc = epc, Tid = tid, Rssi = raw.Rssi, Antenna = raw.AntId };
            bool emitDaemonEvent = false;
            DateTime now = DateTime.UtcNow;
            lock (TagsLock)
            {
                Tags[key] = tag;
                DateTime previous;
                emitDaemonEvent = DaemonMode && (!DaemonLastEmit.TryGetValue(key, out previous) || (now - previous).TotalMilliseconds >= 100);
                if (emitDaemonEvent) DaemonLastEmit[key] = now;
            }
            if (emitDaemonEvent)
            {
                ThreadPool.QueueUserWorkItem(delegate
                {
                    Emit(new { type = "tag", tag = tag, receivedAt = now.ToString("o") });
                });
            }
        }

        private static ParamEpcFilter TidFilter(string tid)
        {
            return new ParamEpcFilter
            {
                Area = 2,
                BitStart = 0,
                BitLength = (byte)(tid.Length * 4),
                HexData = tid,
                BData = HexToBytes(tid)
            };
        }

        private static string TagKey(TagResult tag)
        {
            return (tag.Tid ?? "") + ":" + (tag.Epc ?? "");
        }

        private static bool SetComputerControlledBuzzer(GClient client)
        {
            try
            {
                MsgAppSetBeepOnOff mode = new MsgAppSetBeepOnOff { OnOff = 1 };
                client.SendSynMsg(mode, 2500);
                return mode.RtCode == 0;
            }
            catch { return false; }
        }

        private static BeepResult BeepPulse(GClient client)
        {
            BeepResult result = new BeepResult();
            try
            {
                byte beepType = BridgeSettings.UseControlledBuzzerPulse ? (byte)1 : (byte)0;
                MsgAppSetBeep start = new MsgAppSetBeep { OnOff = 1, BeepType = beepType };
                Stopwatch timer = Stopwatch.StartNew();
                client.SendSynMsg(start, 2500);
                timer.Stop();
                result.StartCommandMs = (int)timer.ElapsedMilliseconds;
                if (start.RtCode != 0) return result;
                if (!BridgeSettings.UseControlledBuzzerPulse)
                {
                    result.Accepted = true;
                    return result;
                }
                bool stopped = false;
                try
                {
                    timer.Restart();
                    Thread.Sleep(BridgeSettings.BuzzerPulseMilliseconds);
                    timer.Stop();
                    result.HoldMs = (int)timer.ElapsedMilliseconds;
                }
                finally
                {
                    MsgAppSetBeep stop = new MsgAppSetBeep { OnOff = 0, BeepType = beepType };
                    timer.Restart();
                    client.SendSynMsg(stop, 2500);
                    timer.Stop();
                    result.StopCommandMs = (int)timer.ElapsedMilliseconds;
                    stopped = stop.RtCode == 0;
                }
                result.Accepted = stopped;
                return result;
            }
            catch { return result; }
        }

        private static BeepResult NativeBeep(GClient client)
        {
            BeepResult result = new BeepResult();
            try
            {
                MsgAppSetBeep beep = new MsgAppSetBeep { OnOff = 1, BeepType = 0 };
                Stopwatch timer = Stopwatch.StartNew();
                client.SendSynMsg(beep, 2500);
                timer.Stop();
                result.StartCommandMs = (int)timer.ElapsedMilliseconds;
                result.Accepted = beep.RtCode == 0;
                return result;
            }
            catch { return result; }
        }

        private static void Stop(GClient client)
        {
            try
            {
                MsgBaseStop stop = new MsgBaseStop();
                client.SendSynMsg(stop, 2500);
            }
            catch { }
        }

        private static byte[] HexToBytes(string value)
        {
            byte[] bytes = new byte[value.Length / 2];
            for (int i = 0; i < bytes.Length; i++) bytes[i] = Convert.ToByte(value.Substring(i * 2, 2), 16);
            return bytes;
        }

        private static bool IsHex(string value)
        {
            return value.All(character => (character >= '0' && character <= '9') || (character >= 'A' && character <= 'F'));
        }

        private static int ClampTimeout(string value)
        {
            int parsed;
            if (!Int32.TryParse(value, out parsed)) return 1600;
            return Math.Max(500, Math.Min(parsed, 10000));
        }

        private static int Fail(string message)
        {
            Emit(new { ok = false, error = message });
            return 1;
        }

        private static void Emit(object payload)
        {
            lock (OutputLock)
            {
                Console.WriteLine(Marker + Json.Serialize(payload));
                Console.Out.Flush();
            }
        }
    }
}
