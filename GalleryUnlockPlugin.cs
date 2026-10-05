using System;
using System.Collections.Generic;
using System.Reflection;
using BepInEx;
using BepInEx.Configuration;
using UnityEngine;
using UnityEngine.UI;

namespace NtrmanGalleryUnlock
{
    [BepInPlugin(PluginGuid, "NTRMAN Gallery Unlocker", PluginVersion)]
    public class GalleryUnlockPlugin : BaseUnityPlugin
    {
        public const string PluginGuid = "ntrman.seasonsofloss.galleryunlock";
        public const string PluginVersion = "1.3.0";

        private const string VideoPresetVar = "g_VideoPreset";

        internal static GalleryUnlockPlugin Instance;

        private static readonly string[] KnownUnlockVars =
        {
            "g_UNLOCK_MOM_MODE",
            "g_UNLOCK_FRIEND_MODE",
            "g_UNLOCK_SCENE_CH_2",
            "g_UNLOCK_SCENE_CH_2_5_SCENE",
            "g_UNLOCK_SCENE_CH_3_5",
            "g_UNLOCK_SCENE_CH_3_5_SCENE",
            "g_UNLOCK_SCENE_CH_4_SCENE",
            "g_UNLOCK_SCENE_CH_5",
            "g_UNLOCK_SCENE_CH_5_SCENE",
            "g_UNLOCK_SCENE_CH_6",
            "g_UNLOCK_SCENE_CH_7_5",
            "g_UNLOCK_SCENE_CH_7_5_SCENE",
            "g_UNLOCK_SCENE_CF_CH_2",
            "g_UNLOCK_SCENE_CF_CH_2_SCENE",
            "g_UNLOCK_SCENE_CF_CH_4",
            "g_UNLOCK_SCENE_CF_CH_5_SCENE",
            "g_UNLOCK_SCENE_CF_CH_6_ALT",
            "g_UNLOCK_SCENE_CF_CH_6_SCENE",
            "g_UNLOCK_SCENE_CF_CH_8_SCENE",
            "g_UNLOCK_SCENE_CF_CH_8_5_SCENE",
            "g_UNLOCK_SCENE_CF_CH_10_SCENE",
        };

        private static readonly HashSet<string> Discovered = new HashSet<string>(StringComparer.Ordinal);
        private static readonly HashSet<int> UnlockEventFired = new HashSet<int>();

        private static Type _engineType;
        private static Type _varManagerType;
        private static Type _stateManagerType;
        private static PropertyInfo _initializedProp;
        private static MethodInfo _getServiceDef;
        private static MethodInfo _closedGetService;
        private static MethodInfo _closedStateGetService;
        private static MethodInfo _getVarValue;
        private static MethodInfo _setVarValue;
        private static MethodInfo _saveGlobal;
        private static bool _reflectionDone;
        private static int _reflectionErrors;

        private static Type _unlockableType;
        private static FieldInfo _fUnlockableId;
        private static bool _firstHookResolved;

        private static Type _thumbType;
        private static Type _loaderType;
        private static FieldInfo _fThumbId;
        private static FieldInfo _fIsUnlocked;
        private static FieldInfo _fUnlockEvent;
        private static MethodInfo _mUnlockInvoke;
        private static MethodInfo _mRecheck;
        private static bool _secondHookResolved;

        private ConfigEntry<bool> _cfgEnabled;
        private ConfigEntry<string> _cfgVideoPreset;
        private ConfigEntry<bool> _cfgVerbose;
        private ConfigEntry<bool> _cfgPersist;
        private ConfigEntry<string> _cfgPrefix;
        private ConfigEntry<KeyCode> _cfgToggleKey;

        internal bool UnlockEnabled;
        private float _nextSweep;
        private bool _dirty;
        private bool _persisted;
        private bool _announcedReady;
        private bool _announcedWaiting;
        private bool _pendingRecheck;
        private float _readyAt;
        private int _changed;
        private int _alreadySet;
        private int _sweepCount;

        private void Awake()
        {
            Instance = this;

            _cfgEnabled = Config.Bind("General", "Enabled", true,
                "Force every gallery entry to be unlocked.");
            _cfgVideoPreset = Config.Bind("Video", "Preset", "H",
                "Gallery video quality preset: U (ultra) / H (high) / M (medium) / L (low). Empty = leave to game.");
            _cfgVerbose = Config.Bind("General", "Verbose", false,
                "Log each gallery unlock variable the plugin discovers at runtime.");
            _cfgPersist = Config.Bind("General", "PersistUnlock", true,
                "Write the unlocked flags into the Naninovel global save once, so the gallery " +
                "stays unlocked even after removing this plugin.");
            _cfgPrefix = Config.Bind("General", "UnlockIdPrefix", string.Empty,
                "Only force unlock ids starting with this prefix. " +
                "Empty = force every gallery gate (works on any game using these hooks).");
            _cfgToggleKey = Config.Bind("General", "ToggleKey", KeyCode.F8,
                "Hotkey that toggles the unlocker at runtime.");

            UnlockEnabled = _cfgEnabled.Value;
            _readyAt = Time.unscaledTime;

            Logger.LogInfo("Loaded. Press " + _cfgToggleKey.Value + " in-game to toggle.");
        }

        private void OnDestroy()
        {
            if (Instance == this)
                Instance = null;
        }

        private void Update()
        {
            if (Input.GetKeyDown(_cfgToggleKey.Value))
            {
                _cfgEnabled.Value = !_cfgEnabled.Value;
                UnlockEnabled = _cfgEnabled.Value;
                _dirty = false;
                _persisted = false;
                _announcedReady = false;
                _pendingRecheck = false;
                UnlockEventFired.Clear();
                _nextSweep = 0f;
                Logger.LogInfo("Gallery unlock " + (UnlockEnabled ? "ENABLED" : "DISABLED") + ".");
            }

            if (!UnlockEnabled)
                return;

            if (Time.unscaledTime >= _nextSweep)
                Sweep();

            TryPersist();
        }

        private void Sweep()
        {
            _nextSweep = Time.unscaledTime + 1f;

            var vm = GetVariableManager();
            if (vm == null)
            {
                if (!_announcedWaiting)
                {
                    _announcedWaiting = true;
                    Logger.LogInfo("Waiting for the Naninovel engine to finish initialising...");
                }
                return;
            }

            if (!_announcedReady)
            {
                _announcedReady = true;
                _announcedWaiting = false;
                Logger.LogInfo("Naninovel engine ready - applying unlock flags.");
                LogHookSupport();
            }

            var prefix = (_cfgPrefix.Value ?? string.Empty).Trim();
            if (prefix.Length == 0)
            {
                for (int i = 0; i < KnownUnlockVars.Length; i++)
                    SetValue(vm, KnownUnlockVars[i], "true", "true");
            }

            ApplyButtonHook(vm);
            ApplyThumbnailHook(vm);
            ApplyVideoPreset(vm);

            _sweepCount++;
            if (_cfgVerbose.Value && _sweepCount <= 4)
            {
                Logger.LogInfo("Sweep #" + _sweepCount + ": forced=" + _changed +
                               ", already-set=" + _alreadySet + ", ids seen=" + Discovered.Count);
            }
        }

        private void ApplyButtonHook(object vm)
        {
            if (!ResolveFirstHook() || _unlockableType == null || _fUnlockableId == null)
                return;

            object[] items;
            try { items = UnityEngine.Object.FindObjectsOfType(_unlockableType); }
            catch { return; }
            if (items == null)
                return;

            for (int i = 0; i < items.Length; i++)
            {
                var id = _fUnlockableId.GetValue(items[i]) as string;
                if (!IsUnlockId(id))
                    continue;

                if (Discovered.Add(id) && _cfgVerbose.Value)
                    Logger.LogInfo("Discovered gallery unlock id: " + id + " (hook: UnlockableCustom)");

                SetValue(vm, id, "true", "true");

                var btn = (items[i] as Component)?.GetComponent(typeof(Button)) as Button;
                if (btn != null && !btn.interactable)
                    btn.interactable = true;
            }
        }

        private void ApplyThumbnailHook(object vm)
        {
            if (!ResolveSecondHook() || _thumbType == null || _fThumbId == null)
                return;

            object[] thumbs;
            try { thumbs = UnityEngine.Object.FindObjectsOfType(_thumbType); }
            catch { return; }
            if (thumbs == null)
                return;

            for (int i = 0; i < thumbs.Length; i++)
            {
                var id = _fThumbId.GetValue(thumbs[i]) as string;
                if (!IsUnlockId(id))
                    continue;

                if (Discovered.Add(id) && _cfgVerbose.Value)
                    Logger.LogInfo("Discovered gallery unlock id: " + id + " (hook: GalleryThumbnail)");

                SetValue(vm, id, "1", "1");

                if (_fIsUnlocked != null && !(bool)_fIsUnlocked.GetValue(thumbs[i]))
                {
                    _fIsUnlocked.SetValue(thumbs[i], true);
                    _pendingRecheck = true;
                }

                var asObj = thumbs[i] as UnityEngine.Object;
                if (_fUnlockEvent != null && _mUnlockInvoke != null && asObj != null)
                {
                    var key = asObj.GetInstanceID();
                    if (!UnlockEventFired.Contains(key))
                    {
                        var evt = _fUnlockEvent.GetValue(thumbs[i]);
                        if (evt != null)
                        {
                            try
                            {
                                _mUnlockInvoke.Invoke(evt, null);
                                UnlockEventFired.Add(key);
                            }
                            catch { }
                        }
                    }
                }

                var btn = (asObj as Component)?.GetComponent(typeof(Button)) as Button;
                if (btn != null && !btn.interactable)
                    btn.interactable = true;
            }

            if (_pendingRecheck && _loaderType != null && _mRecheck != null)
            {
                _pendingRecheck = false;
                try
                {
                    var loaders = UnityEngine.Object.FindObjectsOfType(_loaderType);
                    if (loaders != null)
                        foreach (var l in loaders)
                            _mRecheck.Invoke(l, null);
                }
                catch { }
            }
        }

        private void LogHookSupport()
        {
            var buttonHook = ResolveFirstHook() && _fUnlockableId != null;
            var thumbHook = ResolveSecondHook() && _fThumbId != null;

            var msg = "Gallery hook support: UnlockableCustom=" + (buttonHook ? "yes" : "no")
                    + ", GalleryThumbnail=" + (thumbHook ? "yes" : "no");

            if (thumbHook)
            {
                msg += ", thumb fields="
                    + ((_fIsUnlocked != null && _fUnlockEvent != null) ? "ok" : "PARTIAL")
                    + ", UnityEvent.Invoke=" + (_mUnlockInvoke != null ? "ok" : "MISSING")
                    + ", loader.recheck=" + (_mRecheck != null ? "ok" : "MISSING");
            }

            Logger.LogInfo(msg);

            if (!buttonHook && !thumbHook)
                Logger.LogWarning("Neither gallery hook was found - this title is probably not supported.");
        }

        private void ApplyVideoPreset(object vm)
        {
            var preset = (_cfgVideoPreset.Value ?? string.Empty).Trim();
            if (preset.Length == 0)
                return;

            if (GetVarValue(vm, VideoPresetVar) != preset)
                SetVarValue(vm, VideoPresetVar, preset);
        }

        private void SetValue(object vm, string name, string desired, string compareAs)
        {
            if (string.IsNullOrEmpty(name))
                return;

            var current = GetVarValue(vm, name);
            if (current == compareAs || current == desired)
            {
                _alreadySet++;
                return;
            }

            SetVarValue(vm, name, desired);
            _dirty = true;
            _changed++;
        }

        private void TryPersist()
        {
            if (_persisted || !_dirty || !_cfgPersist.Value || !_cfgEnabled.Value)
                return;
            if (Time.unscaledTime < _readyAt + 10f)
                return;

            _persisted = true;

            if (_saveGlobal == null || _closedStateGetService == null)
            {
                Logger.LogWarning("This Naninovel build exposes no known global-save method, so the " +
                                  "unlock will NOT persist across sessions. It is still applied on every launch.");
                return;
            }

            try
            {
                var stateManager = _closedStateGetService.Invoke(null, BuildArgs(_closedStateGetService));
                if (stateManager == null)
                {
                    Logger.LogWarning("IStateManager was unavailable, so the unlock stays in-memory only.");
                    return;
                }

                _saveGlobal.Invoke(stateManager, null);

                Logger.LogInfo("Unlock flags written to the global save (persisted).");
                _dirty = false;
            }
            catch (Exception e)
            {
                Logger.LogWarning("Could not write the global save: " + Unwrap(e).Message);
            }
        }

        private static bool EngineReady()
        {
            if (!EnsureReflection() || _initializedProp == null)
                return false;

            try { return (bool)_initializedProp.GetValue(null, null); }
            catch { return false; }
        }

        private static object GetVariableManager()
        {
            if (!EngineReady() || _closedGetService == null)
                return null;

            try { return _closedGetService.Invoke(null, BuildArgs(_closedGetService)); }
            catch { return null; }
        }

        private static object[] BuildArgs(MethodInfo closed)
        {
            var ps = closed.GetParameters();
            if (ps.Length == 0)
                return new object[0];

            var args = new object[ps.Length];
            for (int i = 0; i < ps.Length; i++)
                args[i] = ps[i].HasDefaultValue ? ps[i].DefaultValue : null;
            return args;
        }

        private static string GetVarValue(object vm, string name)
        {
            if (vm == null || _getVarValue == null || string.IsNullOrEmpty(name))
                return null;
            try { return _getVarValue.Invoke(vm, new object[] { name }) as string; }
            catch { return null; }
        }

        private static void SetVarValue(object vm, string name, string value)
        {
            if (vm == null || _setVarValue == null)
                return;
            try { _setVarValue.Invoke(vm, new object[] { name, value }); }
            catch { }
        }

        private static bool EnsureReflection()
        {
            if (_reflectionDone)
                return _engineType != null;

            _engineType = FindType("Naninovel.Engine");
            if (_engineType == null)
                return false;

            _varManagerType = FindType("Naninovel.ICustomVariableManager");
            _stateManagerType = FindType("Naninovel.IStateManager");

            _initializedProp = _engineType.GetProperty("Initialized",
                BindingFlags.Public | BindingFlags.Static);

            foreach (var m in _engineType.GetMethods(BindingFlags.Public | BindingFlags.Static))
            {
                if (m.Name == "GetService" && m.IsGenericMethodDefinition)
                {
                    _getServiceDef = m;
                    break;
                }
            }

            if (_getServiceDef != null && _varManagerType != null)
            {
                _closedGetService = _getServiceDef.MakeGenericMethod(_varManagerType);
                _getVarValue = _varManagerType.GetMethod("GetVariableValue");
                _setVarValue = _varManagerType.GetMethod("SetVariableValue");
            }

            if (_getServiceDef != null && _stateManagerType != null)
            {
                _closedStateGetService = _getServiceDef.MakeGenericMethod(_stateManagerType);
                foreach (var name in new[] { "SaveGlobalAsync", "SaveGlobalStateAsync" })
                {
                    _saveGlobal = _stateManagerType.GetMethod(name, Type.EmptyTypes);
                    if (_saveGlobal != null)
                        break;
                }
            }

            _reflectionDone = true;

            if (_closedGetService == null && _reflectionErrors++ < 2)
            {
                var log = Instance != null ? Instance.Logger : null;
                if (log != null)
                    log.LogError("Naninovel reflection failed: could not bind GetService<ICustomVariableManager>.");
            }

            return true;
        }

        private static bool ResolveFirstHook()
        {
            if (_firstHookResolved)
                return _unlockableType != null;

            _unlockableType = FindType("UnlockableCustom");
            if (_unlockableType == null)
                return false;

            _fUnlockableId = _unlockableType.GetField("unlockID");
            _firstHookResolved = true;
            return true;
        }

        private static bool ResolveSecondHook()
        {
            if (_secondHookResolved)
                return _thumbType != null;

            _thumbType = FindType("GalleryThumbnail");
            if (_thumbType == null)
                return false;

            _loaderType = FindType("GalleryLoader");

            _fThumbId = _thumbType.GetField("unlockID");
            _fIsUnlocked = _thumbType.GetField("isUnlocked");
            _fUnlockEvent = _thumbType.GetField("Unlock");

            if (_fUnlockEvent != null)
                _mUnlockInvoke = _fUnlockEvent.FieldType.GetMethod("Invoke");

            if (_loaderType != null)
                _mRecheck = _loaderType.GetMethod("recheck", Type.EmptyTypes);

            _secondHookResolved = true;
            return true;
        }

        private static Type FindType(string fullName)
        {
            try
            {
                foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
                {
                    var t = asm.GetType(fullName, false);
                    if (t != null)
                        return t;
                }
            }
            catch { }
            return null;
        }

        private static Exception Unwrap(Exception e)
        {
            while (e is TargetInvocationException tie && tie.InnerException != null)
                e = tie.InnerException;
            return e;
        }

        private bool IsUnlockId(string id)
        {
            if (string.IsNullOrEmpty(id))
                return false;

            var prefix = (_cfgPrefix.Value ?? string.Empty).Trim();
            if (prefix.Length == 0)
                return true;

            return id.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }
    }
}