local GitHubAuth = require("github_auth")

test("github auth sees MISE_GITHUB_TOKEN as supported auth", function()
    with_env({
        GITHUB_TOKEN = false,
        GH_TOKEN = false,
        MISE_GITHUB_TOKEN = "mise-token",
    }, function()
        assert_truthy(GitHubAuth.token_env_present())
    end)
end)

test("github auth treats empty token env vars as absent", function()
    with_env({
        GITHUB_TOKEN = "",
        GH_TOKEN = "",
        MISE_GITHUB_TOKEN = false,
    }, function()
        assert_falsey(GitHubAuth.token_env_present())
        assert_equal(GitHubAuth.curl_auth_header(), "")
    end)
end)

test("github auth header defers token expansion to the shell", function()
    with_env({
        GITHUB_TOKEN = "",
        GH_TOKEN = "",
        MISE_GITHUB_TOKEN = "mise-token",
    }, function()
        local header = GitHubAuth.curl_auth_header()
        assert_contains(header, "Authorization: token")
        assert_contains(header, "MISE_GITHUB_TOKEN")
        assert_not_contains(header, "mise-token", "auth header must not inline credential material")
    end)
end)

test("github auth scrub prefix clears every supported token env var", function()
    assert_equal(
        GitHubAuth.scrub_env_prefix(),
        "env -u GITHUB_TOKEN -u GH_TOKEN -u MISE_GITHUB_TOKEN "
    )
end)
