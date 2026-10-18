import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/update/github_token_store.dart';

void main() {
  test('normalizes supported GitHub token shapes without exposing them', () {
    expect(
      GitHubTokenStore.normalize(' github_pat_test_token '),
      'github_pat_test_token',
    );
    expect(GitHubTokenStore.normalize(null), isNull);
    expect(
      () => GitHubTokenStore.normalize('not-a-token'),
      throwsFormatException,
    );
    expect(
      () => GitHubTokenStore.normalize('github_pat_bad token'),
      throwsFormatException,
    );
  });
}
