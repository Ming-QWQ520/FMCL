package dev.mingqwq.fmcl

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * FMCL Android 入口 Activity。
 *
 * 当前为预览/占位实现：界面可运行，但游戏启动链路依赖的能力
 * （JRE 管理、进程派生、Rust 动态库）尚未在 Android 端接入。
 *
 * 完整的平台适配路线图见项目根目录 [TODO.md]，编号 A-01 ~ A-09。
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "fmcl/platform"
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
                            "sdkInt" to android.os.Build.VERSION.SDK_INT,
                        )
                    )
                }
                // TODO(ANDROID) #A-06: 返回授权存储目录（SAF / MANAGE_EXTERNAL_STORAGE）
                "storagePaths" -> {
                    result.success(
                        mapOf(
                            "appPrivate" to filesDir.absolutePath,
                            // TODO(ANDROID): 外部存储路径需运行时申请权限
                            "external" to getExternalFilesDir(null)?.absolutePath,
                        )
                    )
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
    }
}
