using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Nxb.Semantic
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct SW_DEVICE_CREATE_INFO
    {
        internal uint cbSize;
        [MarshalAs(UnmanagedType.LPWStr)] internal string pszInstanceId;
        internal IntPtr pszzHardwareIds;
        internal IntPtr pszzCompatibleIds;
        internal IntPtr pContainerId;
        internal uint CapabilityFlags;
        [MarshalAs(UnmanagedType.LPWStr)] internal string pszDeviceDescription;
        [MarshalAs(UnmanagedType.LPWStr)] internal string pszDeviceLocation;
        internal IntPtr pSecurityDescriptor;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SP_DEVINFO_DATA
    {
        internal uint cbSize;
        internal Guid ClassGuid;
        internal uint DevInst;
        internal UIntPtr Reserved;
    }

    internal static class PnpNativeMethods
    {
        internal const uint CR_SUCCESS = 0x00000000;
        internal const uint CM_LOCATE_DEVNODE_NORMAL = 0x00000000;
        internal const uint DICD_GENERATE_ID = 0x00000001;
        internal const uint DIF_REMOVE = 0x00000005;
        internal const uint DIF_REGISTERDEVICE = 0x00000019;
        internal static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)]
        internal delegate void SW_DEVICE_CREATE_CALLBACK(
            IntPtr hSwDevice,
            int createResult,
            IntPtr context,
            [MarshalAs(UnmanagedType.LPWStr)] string deviceInstanceId);

        [DllImport("Cfgmgr32.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Winapi)]
        internal static extern int SwDeviceCreate(
            string pszEnumeratorName,
            string pszParentDeviceInstance,
            ref SW_DEVICE_CREATE_INFO pCreateInfo,
            uint cPropertyCount,
            IntPtr pProperties,
            SW_DEVICE_CREATE_CALLBACK pCallback,
            IntPtr pContext,
            out IntPtr phSwDevice);

        [DllImport("Cfgmgr32.dll", CallingConvention = CallingConvention.Winapi)]
        internal static extern void SwDeviceClose(IntPtr hSwDevice);

        [DllImport("Cfgmgr32.dll", EntryPoint = "CM_Locate_DevNodeW", CharSet = CharSet.Unicode)]
        internal static extern uint CM_Locate_DevNodeW(
            out uint pdnDevInst,
            string pDeviceId,
            uint ulFlags);

        [DllImport("Setupapi.dll", SetLastError = true)]
        internal static extern IntPtr SetupDiCreateDeviceInfoList(
            IntPtr classGuid,
            IntPtr hwndParent);

        [DllImport("Setupapi.dll", EntryPoint = "SetupDiCreateDeviceInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetupDiCreateDeviceInfoW(
            IntPtr deviceInfoSet,
            string deviceName,
            ref Guid classGuid,
            string deviceDescription,
            IntPtr hwndParent,
            uint creationFlags,
            ref SP_DEVINFO_DATA deviceInfoData);

        [DllImport("Setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetupDiCallClassInstaller(
            uint installFunction,
            IntPtr deviceInfoSet,
            ref SP_DEVINFO_DATA deviceInfoData);

        [DllImport("Setupapi.dll", EntryPoint = "SetupDiGetDeviceInstanceIdW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetupDiGetDeviceInstanceIdW(
            IntPtr deviceInfoSet,
            ref SP_DEVINFO_DATA deviceInfoData,
            StringBuilder deviceInstanceId,
            uint deviceInstanceIdSize,
            out uint requiredSize);

        [DllImport("Setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);
    }

    public sealed class PnpFixtureLease : IDisposable
    {
        private IntPtr softwareDeviceHandle;
        private IntPtr setupDeviceInfoSet;
        private SP_DEVINFO_DATA setupDeviceInfoData;
        private bool setupDeviceRegistered;

        public string InstanceId { get; private set; }
        public string Backend { get; private set; }
        public int PrimarySoftwareDeviceFailureHResult { get; private set; }
        public bool Closed { get; private set; }

        private PnpFixtureLease()
        {
            softwareDeviceHandle = IntPtr.Zero;
            setupDeviceInfoSet = IntPtr.Zero;
            setupDeviceInfoData = default(SP_DEVINFO_DATA);
            PrimarySoftwareDeviceFailureHResult = 0;
        }

        public static bool IsPresent(string instanceId)
        {
            if (String.IsNullOrWhiteSpace(instanceId))
            {
                return false;
            }

            uint devInst;
            uint result = PnpNativeMethods.CM_Locate_DevNodeW(
                out devInst,
                instanceId,
                PnpNativeMethods.CM_LOCATE_DEVNODE_NORMAL);
            return result == PnpNativeMethods.CR_SUCCESS;
        }

        public static PnpFixtureLease Create(string instanceSeed)
        {
            if (String.IsNullOrWhiteSpace(instanceSeed))
            {
                throw new ArgumentException("instanceSeed");
            }

            try
            {
                return CreateSoftwareDevice(instanceSeed);
            }
            catch (Exception exception) when (IsFallbackEligible(exception))
            {
                return CreateSetupApiRootDevice(instanceSeed, exception.HResult);
            }
        }

        private static bool IsFallbackEligible(Exception exception)
        {
            if (exception is DllNotFoundException || exception is EntryPointNotFoundException)
            {
                return true;
            }

            return exception.HResult == unchecked((int)0x8007007E);
        }

        private static PnpFixtureLease CreateSoftwareDevice(string instanceSeed)
        {
            SW_DEVICE_CREATE_INFO info = new SW_DEVICE_CREATE_INFO
            {
                cbSize = (uint)Marshal.SizeOf(typeof(SW_DEVICE_CREATE_INFO)),
                pszInstanceId = instanceSeed,
                pszzHardwareIds = IntPtr.Zero,
                pszzCompatibleIds = IntPtr.Zero,
                pContainerId = IntPtr.Zero,
                CapabilityFlags = 0x00000001u | 0x00000002u | 0x00000004u,
                pszDeviceDescription = "NXB Semantic Ephemeral Software Device",
                pszDeviceLocation = null,
                pSecurityDescriptor = IntPtr.Zero
            };

            using (ManualResetEventSlim ready = new ManualResetEventSlim(false))
            {
                int callbackResult = unchecked((int)0x80004005);
                string actualId = null;
                PnpNativeMethods.SW_DEVICE_CREATE_CALLBACK callback = (device, result, context, id) =>
                {
                    callbackResult = result;
                    actualId = id;
                    ready.Set();
                };

                IntPtr handle;
                int immediateResult = PnpNativeMethods.SwDeviceCreate(
                    "NXBSEM",
                    "HTREE\\ROOT\\0",
                    ref info,
                    0,
                    IntPtr.Zero,
                    callback,
                    IntPtr.Zero,
                    out handle);
                if (immediateResult < 0)
                {
                    Marshal.ThrowExceptionForHR(immediateResult);
                }

                if (!ready.Wait(TimeSpan.FromSeconds(10)))
                {
                    if (handle != IntPtr.Zero)
                    {
                        PnpNativeMethods.SwDeviceClose(handle);
                    }
                    throw new TimeoutException("SwDeviceCreate callback timed out.");
                }

                GC.KeepAlive(callback);
                if (callbackResult < 0)
                {
                    if (handle != IntPtr.Zero)
                    {
                        PnpNativeMethods.SwDeviceClose(handle);
                    }
                    Marshal.ThrowExceptionForHR(callbackResult);
                }

                if (String.IsNullOrWhiteSpace(actualId))
                {
                    if (handle != IntPtr.Zero)
                    {
                        PnpNativeMethods.SwDeviceClose(handle);
                    }
                    throw new InvalidOperationException("SwDeviceCreate callback returned no instance id.");
                }

                return new PnpFixtureLease
                {
                    softwareDeviceHandle = handle,
                    InstanceId = actualId,
                    Backend = "software_device_api"
                };
            }
        }

        private static PnpFixtureLease CreateSetupApiRootDevice(string instanceSeed, int primaryFailureHResult)
        {
            IntPtr deviceInfoSet = PnpNativeMethods.SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (deviceInfoSet == PnpNativeMethods.INVALID_HANDLE_VALUE)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList failed.");
            }

            SP_DEVINFO_DATA deviceInfoData = new SP_DEVINFO_DATA
            {
                cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA)),
                ClassGuid = Guid.Empty,
                DevInst = 0,
                Reserved = UIntPtr.Zero
            };
            bool registered = false;
            try
            {
                Guid classGuid = Guid.Empty;
                string generatedRootId = "NXBSEMANTIC-" + NormalizeSeed(instanceSeed);
                if (!PnpNativeMethods.SetupDiCreateDeviceInfoW(
                    deviceInfoSet,
                    generatedRootId,
                    ref classGuid,
                    "NXB Semantic Ephemeral Root Device",
                    IntPtr.Zero,
                    PnpNativeMethods.DICD_GENERATE_ID,
                    ref deviceInfoData))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoW failed.");
                }

                if (!PnpNativeMethods.SetupDiCallClassInstaller(
                    PnpNativeMethods.DIF_REGISTERDEVICE,
                    deviceInfoSet,
                    ref deviceInfoData))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "DIF_REGISTERDEVICE failed.");
                }
                registered = true;

                string instanceId = GetSetupApiInstanceId(deviceInfoSet, ref deviceInfoData);
                if (String.IsNullOrWhiteSpace(instanceId))
                {
                    throw new InvalidOperationException("SetupAPI root fixture returned no instance id.");
                }

                return new PnpFixtureLease
                {
                    setupDeviceInfoSet = deviceInfoSet,
                    setupDeviceInfoData = deviceInfoData,
                    setupDeviceRegistered = true,
                    InstanceId = instanceId,
                    Backend = "setupapi_root_fallback",
                    PrimarySoftwareDeviceFailureHResult = primaryFailureHResult
                };
            }
            catch
            {
                if (registered)
                {
                    try
                    {
                        PnpNativeMethods.SetupDiCallClassInstaller(
                            PnpNativeMethods.DIF_REMOVE,
                            deviceInfoSet,
                            ref deviceInfoData);
                    }
                    catch
                    {
                    }
                }

                PnpNativeMethods.SetupDiDestroyDeviceInfoList(deviceInfoSet);
                throw;
            }
        }

        private static string NormalizeSeed(string seed)
        {
            StringBuilder builder = new StringBuilder();
            foreach (char character in seed.ToUpperInvariant())
            {
                if ((character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9'))
                {
                    builder.Append(character);
                }
                else
                {
                    builder.Append('-');
                }

                if (builder.Length >= 80)
                {
                    break;
                }
            }

            if (builder.Length == 0)
            {
                builder.Append(Guid.NewGuid().ToString("N").ToUpperInvariant());
            }
            return builder.ToString();
        }

        private static string GetSetupApiInstanceId(IntPtr deviceInfoSet, ref SP_DEVINFO_DATA deviceInfoData)
        {
            uint requiredSize;
            StringBuilder buffer = new StringBuilder(512);
            if (PnpNativeMethods.SetupDiGetDeviceInstanceIdW(
                deviceInfoSet,
                ref deviceInfoData,
                buffer,
                (uint)buffer.Capacity,
                out requiredSize))
            {
                return buffer.ToString();
            }

            int error = Marshal.GetLastWin32Error();
            const int ERROR_INSUFFICIENT_BUFFER = 122;
            if (error != ERROR_INSUFFICIENT_BUFFER || requiredSize == 0)
            {
                throw new Win32Exception(error, "SetupDiGetDeviceInstanceIdW failed.");
            }

            buffer = new StringBuilder((int)requiredSize);
            if (!PnpNativeMethods.SetupDiGetDeviceInstanceIdW(
                deviceInfoSet,
                ref deviceInfoData,
                buffer,
                (uint)buffer.Capacity,
                out requiredSize))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetDeviceInstanceIdW failed.");
            }
            return buffer.ToString();
        }

        public void Close()
        {
            if (Closed)
            {
                return;
            }

            if (softwareDeviceHandle != IntPtr.Zero)
            {
                PnpNativeMethods.SwDeviceClose(softwareDeviceHandle);
                softwareDeviceHandle = IntPtr.Zero;
            }

            if (setupDeviceInfoSet != IntPtr.Zero && setupDeviceInfoSet != PnpNativeMethods.INVALID_HANDLE_VALUE)
            {
                Exception removalFailure = null;
                if (setupDeviceRegistered)
                {
                    if (!PnpNativeMethods.SetupDiCallClassInstaller(
                        PnpNativeMethods.DIF_REMOVE,
                        setupDeviceInfoSet,
                        ref setupDeviceInfoData))
                    {
                        removalFailure = new Win32Exception(Marshal.GetLastWin32Error(), "DIF_REMOVE failed.");
                    }
                    else
                    {
                        setupDeviceRegistered = false;
                    }
                }

                bool destroyed = PnpNativeMethods.SetupDiDestroyDeviceInfoList(setupDeviceInfoSet);
                int destroyError = destroyed ? 0 : Marshal.GetLastWin32Error();
                setupDeviceInfoSet = IntPtr.Zero;

                if (removalFailure != null)
                {
                    throw removalFailure;
                }
                if (!destroyed)
                {
                    throw new Win32Exception(destroyError, "SetupDiDestroyDeviceInfoList failed.");
                }
            }

            Closed = true;
        }

        public void Dispose()
        {
            Close();
        }
    }
}
