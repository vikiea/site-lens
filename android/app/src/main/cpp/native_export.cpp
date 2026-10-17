#include <jni.h>
#include <string>

namespace {
bool inside(const std::string& path, const std::string& root) {
  if (path == root) return true;
  if (path.size() <= root.size() || path.compare(0, root.size(), root) != 0) {
    return false;
  }
  return path[root.size()] == '/';
}
}

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_vikiea_site_1lens_NativeExportRuntime_nativeValidatePath(
    JNIEnv* env, jobject /* self */, jstring path, jstring root) {
  if (path == nullptr || root == nullptr) return JNI_FALSE;
  const char* path_chars = env->GetStringUTFChars(path, nullptr);
  const char* root_chars = env->GetStringUTFChars(root, nullptr);
  const std::string path_value(path_chars ? path_chars : "");
  const std::string root_value(root_chars ? root_chars : "");
  if (path_chars) env->ReleaseStringUTFChars(path, path_chars);
  if (root_chars) env->ReleaseStringUTFChars(root, root_chars);
  if (path_value.empty() || root_value.empty() || path_value.find("..") != std::string::npos) {
    return JNI_FALSE;
  }
  return inside(path_value, root_value) ? JNI_TRUE : JNI_FALSE;
}
