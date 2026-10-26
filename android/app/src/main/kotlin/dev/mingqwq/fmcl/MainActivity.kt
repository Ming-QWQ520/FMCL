package dev.mingqwq.fmcl

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FMCL Android 入口 Activity。
 *
 * 当前为预览实现：界面可运行、联网能力（版本清单 / 下载 / 登录 / 服务器查询）
 * 可用；游戏启动链路依赖的能力（JRE 管理、进程派生、Rust 动态库）尚未接入。
 *
 * 完整的平台适配路线图见项目根目录 [TODO.md]，编号 A-01 ~ A-09。
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "fmcl/platform"

        /// Android 9- 的传统读写存储权限
        const val REQ_STORAGE_LEGACY = 0xF10

        /// Android 11+ 全量存储访问授权页跳转标记
        const val REQ_MANAGE_STORAGE = 0xF11
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 平台通道：为 Android 适配预留的能力桥（部分已实现，部分留桩）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call, result ->
            when (call.method) {
                // 已实现：返回设备基本信息（供 Dart 层降级判断）
                "deviceInfo" -> {
                    result.success(
                        mapOf(
                            "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
                            "model" to Build.MODEL,
                            "sdkInt" to Build.VERSION.SDK_INT,
                        )
                    )
                }
                // #A-06：存储目录与授权状态（供 Dart 层引导授权）
                "storagePaths" -> {
                    result.success(
                        mapOf(
                            "appPrivate" to filesDir.absolutePath,
                            "external" to getExternalFilesDir(null)?.absolutePath,
                            "publicDownloads" to
                                Environment.getExternalStoragePublicDirectory(
                                    Environment.DIRECTORY_DOWNLOADS
                                ).absolutePath,
                            "hasStorage" to hasStorageAccess(),
                        )
                    )
                }
                // #A-06：运行时申请存储权限（传统 READ/WRITE 或 MANAGE_EXTERNAL_STORAGE 引导）
                "requestStoragePermission" -> {
                    requestStorageAccess()
                    result.success(true)
                }
                // TODO(ANDROID) #A-05: Java 运行时检测（扫描 Termux JRE / 内置 runtime）
                "detectJava" -> {
                    result.error("UNIMPLEMENTED", "Android Java 检测尚未实现，见 TODO.md #A-05", null)
                }
                // TODO(ANDROID) #A-01: 游戏进程派生（需 JRE + fork/exec 方案）
                "spawnGame" -> {
                    result.error("UNIMPLEMENTED", "Android 启动游戏尚未实现，见 TODO.md #A-01", null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // TODO(ANDROID) #A-04: 首次启动引导用户选择游戏目录（SAF）
        // 启动即申请存储权限（下载 / 导入整合包 / 游戏目录管理需要）
        requestStorageAccess()
    }

    /// 是否已具备存储访问能力
    private fun hasStorageAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    /// 申请存储访问：
    /// - Android 11+：跳转系统「所有文件访问」授权页（MANAGE_EXTERNAL_STORAGE）
    /// - Android 9-：运行时请求 READ/WRITE_EXTERNAL_STORAGE
    private fun requestStorageAccess() {
        if (hasStorageAccess()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivityForResult(intent, REQ_MANAGE_STORAGE)
            } catch (_: Exception) {
                // 个别 ROM 无此 action，退回通用授权页
                try {
                    val fallback = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivityForResult(fallback, REQ_MANAGE_STORAGE)
                } catch (_: Exception) {
                    // 授权页不可达时静默降级：应用内私有目录仍可用
                }
            }
        } else {
            val perms = arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            )
            ActivityCompat.requestPermissions(this, perms, REQ_STORAGE_LEGACY)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // 结果由 hasStorageAccess 按需查询，这里仅记录
        if (requestCode == REQ_STORAGE_LEGACY) {
            val granted = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            android.util.Log.i("FMCL", "存储权限申请结果: granted=$granted")
        }
    }
}
