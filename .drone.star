#
# We are building GCC with make and Clang with ninja, the combinations are more
# or less arbitrarily chosen. We just want to check that both compilers and both
# CMake generators work. It's unlikely that a specific generator only breaks
# with a specific compiler.
#

DEFAULT_PHP_VERSION = "7.4"
GUI_TEST_DIR = "/drone/src/test/gui"
GUI_TEST_REPORT_DIR = "/drone/src/test/guiReportUpload"
NOTIFICATION_TEMPLATE_DIR = "/drone/src"
STACKTRACE_FILE = "%s/stacktrace.log" % GUI_TEST_REPORT_DIR

CYTOPIA_BLACK = "cytopia/black"
DOCKER_GIT = "docker:git"
MYSQL = "mysql:8.0"
OC_CI_ALPINE = "owncloudci/alpine:latest"
OC_CI_BAZEL_BUILDIFIER = "owncloudci/bazel-buildifier"
OC_CI_CLIENT = "owncloudci/client:latest"
OC_CI_CORE = "owncloudci/core"
OC_CI_DRONE_CANCEL_PREVIOUS_BUILDS = "owncloudci/drone-cancel-previous-builds"
OC_CI_PHP = "owncloudci/php:%s"
OC_CI_SQUISH = "owncloudci/squish:6.7-20220106-1008-qt515x-linux64"
OC_CI_TRANSIFEX = "owncloudci/transifex:latest"
OC_TEST_MIDDLEWARE = "owncloud/owncloud-test-middleware:1.6.0"
OC_UBUNTU = "owncloud/ubuntu:20.04"
PLUGINS_GIT_ACTION = "plugins/git-action:1"
PLUGINS_S3 = "plugins/s3"
PLUGINS_SLACK = "plugins/slack"
PYTHON = "python"
THEGEEKLAB_DRONE_GITHUB_COMMENT = "thegeeklab/drone-github-comment:1"
TOOLHIPPIE_CALENS = "toolhippie/calens:latest"
OC_CI_DRONE_SKIP_PIPELINE = "owncloudci/drone-skip-pipeline"

dir = {
    "base": "/drone",
}

def main(ctx):
    build_trigger = {
        "ref": [
            "refs/heads/master",
            "refs/heads/2.**",
            "refs/tags/**",
            "refs/pull/**",
        ],
    }
    cron_trigger = {
        "event": [
            "cron",
        ],
    }
    pipelines = [
        cancelPreviousBuilds(),
        # check the format of gui test code
        gui_tests_format(build_trigger),
        # Check starlark
        check_starlark(
            ctx,
            build_trigger,
        ),
        # Build changelog
        changelog(
            ctx,
            trigger = build_trigger,
            depends_on = [],
        ),
        build_and_test_client(
            ctx,
            "clang",
            "clang++",
            "Debug",
            "Ninja",
            trigger = build_trigger,
        ),
        gui_tests(ctx, trigger = build_trigger, version = "latest"),
    ]
    cron_pipelines = [
        # Build client
        build_and_test_client(
            ctx,
            "gcc",
            "g++",
            "Release",
            "Unix Makefiles",
            trigger = cron_trigger,
        ),
        build_and_test_client(
            ctx,
            "clang",
            "clang++",
            "Debug",
            "Ninja",
            trigger = cron_trigger,
        ),
        gui_tests(ctx, trigger = cron_trigger),
        notification(
            name = "build",
            trigger = cron_trigger,
            depends_on = [
                "clang-debug-ninja",
                "GUI-tests",
            ],
        ),
    ]

    if ctx.build.event == "cron":
        return cron_pipelines
    else:
        return pipelines

def whenOnline(dict):
    if not "when" in dict:
        dict["when"] = {}

    if not "instance" in dict:
        dict["when"]["instance"] = []

    dict["when"]["instance"].append("drone.owncloud.com")

    return dict

def whenPush(dict):
    if not "when" in dict:
        dict["when"] = {}

    if not "event" in dict:
        dict["when"]["event"] = []

    dict["when"]["event"].append("push")

    return dict

def from_secret(name):
    return {
        "from_secret": name,
    }

def check_starlark(ctx, trigger = {}, depends_on = []):
    return {
        "kind": "pipeline",
        "type": "docker",
        "name": "check-starlark",
        "steps": [
            {
                "name": "format-check-starlark",
                "image": OC_CI_BAZEL_BUILDIFIER,
                "commands": [
                    "buildifier --mode=check .drone.star",
                ],
            },
            {
                "name": "show-diff",
                "image": OC_CI_BAZEL_BUILDIFIER,
                "commands": [
                    "buildifier --mode=fix .drone.star",
                    "git diff",
                ],
                "when": {
                    "status": [
                        "failure",
                    ],
                },
            },
        ],
        "depends_on": depends_on,
        "trigger": trigger,
    }

def build_and_test_client(ctx, c_compiler, cxx_compiler, build_type, generator, trigger = {}, depends_on = []):
    build_command = "ninja" if generator == "Ninja" else "make"
    pipeline_name = c_compiler + "-" + build_type.lower() + "-" + build_command
    build_dir = "build-" + pipeline_name

    return {
        "kind": "pipeline",
        "name": pipeline_name,
        "platform": {
            "os": "linux",
            "arch": "amd64",
        },
        "steps": skipIfUnchanged(ctx, "unit-tests") + [
                     {
                         "name": "submodules",
                         "image": DOCKER_GIT,
                         "commands": [
                             "git submodule update --init --recursive",
                         ],
                     },
                 ] +
                 build_client(ctx, c_compiler, cxx_compiler, build_type, generator, build_command, build_dir) +
                 [
                     {
                         "name": "ctest",
                         "image": OC_CI_CLIENT,
                         "environment": {
                             "LC_ALL": "C.UTF-8",
                         },
                         "commands": [
                             'cd "' + build_dir + '"',
                             "useradd -m -s /bin/bash tester",
                             "chown -R tester:tester .",
                             "su-exec tester ctest --output-on-failure -LE nodrone",
                         ],
                     },
                 ],
        "trigger": trigger,
        "depends_on": depends_on,
    }

def gui_tests(ctx, trigger = {}, depends_on = [], filterTags = [], version = "daily-master-qa"):
    pipeline_name = "GUI-tests"
    build_dir = "build-" + pipeline_name
    squish_parameters = "--reportgen html,%s --envvar QT_LOGGING_RULES=sync.httplogger=true;gui.socketapi=false --tags ~@skip" % GUI_TEST_REPORT_DIR

    if (len(filterTags) > 0):
        for tags in filterTags:
            squish_parameters += " --tags " + tags
            pipeline_name += "-" + tags

    return {
        "kind": "pipeline",
        "name": pipeline_name,
        "platform": {
            "os": "linux",
            "arch": "amd64",
        },
        "steps": skipIfUnchanged(ctx, "gui-tests") + [
                     {
                         "name": "submodules",
                         "image": DOCKER_GIT,
                         "commands": [
                             "git submodule update --init --recursive",
                         ],
                     },
                 ] +
                 installCore(version) +
                 setupServerAndApp(2) +
                 fixPermissions() +
                 owncloudLog() +
                 setGuiTestReportDir() +
                 build_client(ctx, "gcc", "g++", "Debug", "Ninja", "ninja", build_dir) +
                 [
                     {
                         "name": "GUItests",
                         "image": OC_CI_SQUISH,
                         "environment": {
                             "LICENSEKEY": from_secret("squish_license_server"),
                             "GUI_TEST_REPORT_DIR": GUI_TEST_REPORT_DIR,
                             "CLIENT_REPO": "/drone/src/",
                             "MIDDLEWARE_URL": "http://testmiddleware:3000/",
                             "BACKEND_HOST": "http://owncloud/",
                             "SECURE_BACKEND_HOST": "https://owncloud/",
                             "SERVER_INI": "/drone/src/test/gui/drone/server.ini",
                             "SQUISH_PARAMETERS": squish_parameters,
                             "STACKTRACE_FILE": STACKTRACE_FILE,
                         },
                     },
                 ] +
                 # GUI test result has been disabled for now, as we squish can not produce the result in both html and json format.
                 # Disabled untill the feature to generate json result is implemented in squish, or some other method to reuse the log parser is implemented.
                 #  showGuiTestResult() +
                 uploadGuiTestLogs() +
                 buildGithubComment(pipeline_name) +
                 githubComment(pipeline_name),
        "services": testMiddlewareService() +
                    owncloudService() +
                    databaseService(),
        "trigger": trigger,
        "depends_on": depends_on,
        "volumes": [
            {
                "name": "uploads",
                "temp": {},
            },
        ],
    }

def build_client(ctx, c_compiler, cxx_compiler, build_type, generator, build_command, build_dir):
    return [
        {
            "name": "cmake",
            "image": OC_CI_CLIENT,
            "environment": {
                "LC_ALL": "C.UTF-8",
            },
            "commands": [
                'mkdir -p "' + build_dir + '"',
                'cd "' + build_dir + '"',
                'cmake -G"' + generator + '" -DCMAKE_C_COMPILER="' + c_compiler + '" -DCMAKE_CXX_COMPILER="' + cxx_compiler + '" -DCMAKE_BUILD_TYPE="' + build_type + '" -DBUILD_TESTING=1 -DWITH_LIBCLOUDPROVIDERS=ON -S ..',
            ],
        },
        {
            "name": build_command,
            "image": OC_CI_CLIENT,
            "environment": {
                "LC_ALL": "C.UTF-8",
            },
            "commands": [
                'cd "' + build_dir + '"',
                build_command + " -j4",
            ],
        },
    ]

def gui_tests_format(trigger):
    return {
        "kind": "pipeline",
        "type": "docker",
        "name": "guitestformat",
        "steps": [
            {
                "name": "black",
                "image": CYTOPIA_BLACK,
                "commands": [
                    "cd /drone/src/test/gui",
                    "black --check --diff .",
                ],
            },
        ],
        "trigger": trigger,
    }

def changelog(ctx, trigger = {}, depends_on = []):
    repo_slug = ctx.build.source_repo if ctx.build.source_repo else ctx.repo.slug
    result = {
        "kind": "pipeline",
        "type": "docker",
        "name": "changelog",
        "clone": {
            "disable": True,
        },
        "steps": [
            {
                "name": "clone",
                "image": PLUGINS_GIT_ACTION,
                "settings": {
                    "actions": [
                        "clone",
                    ],
                    "remote": "https://github.com/%s" % (repo_slug),
                    "branch": ctx.build.source if ctx.build.event == "pull_request" else "master",
                    "path": "/drone/src",
                    "netrc_machine": "github.com",
                    "netrc_username": from_secret("github_username"),
                    "netrc_password": from_secret("github_token"),
                },
            },
            {
                "name": "generate",
                "image": TOOLHIPPIE_CALENS,
                "commands": [
                    "calens >| CHANGELOG.md",
                ],
            },
            {
                "name": "diff",
                "image": OC_CI_ALPINE,
                "commands": [
                    "git diff",
                ],
            },
            {
                "name": "output",
                "image": TOOLHIPPIE_CALENS,
                "commands": [
                    "cat CHANGELOG.md",
                ],
            },
            {
                "name": "publish",
                "image": PLUGINS_GIT_ACTION,
                "settings": {
                    "actions": [
                        "commit",
                        "push",
                    ],
                    "message": "Automated changelog update [skip ci]",
                    "branch": "master",
                    "author_email": "devops@owncloud.com",
                    "author_name": "ownClouders",
                    "netrc_machine": "github.com",
                    "netrc_username": from_secret("github_username"),
                    "netrc_password": from_secret("github_token"),
                },
                "when": {
                    "ref": {
                        "exclude": [
                            "refs/pull/**",
                            "refs/tags/**",
                        ],
                    },
                },
            },
        ],
        "trigger": trigger,
        "depends_on": depends_on,
    }

    return result

def make(target, path, image = OC_CI_TRANSIFEX):
    return {
        "name": target,
        "image": image,
        "environment": {
            "TX_TOKEN": from_secret("tx_token"),
        },
        "commands": [
            'cd "' + path + '"',
            "make " + target,
        ],
    }

def notification(name, depends_on = [], trigger = {}):
    trigger = dict(trigger)
    if not "status" in trigger:
        trigger["status"] = []

    trigger["status"].append("success")
    trigger["status"].append("failure")

    return {
        "kind": "pipeline",
        "name": "notifications-" + name,
        "platform": {
            "os": "linux",
            "arch": "amd64",
        },
        "steps": [
            {
                "name": "create-template",
                "image": OC_CI_ALPINE,
                "environment": {
                    "CACHE_ENDPOINT": {
                        "from_secret": "cache_public_s3_server",
                    },
                    "CACHE_BUCKET": {
                        "from_secret": "cache_public_s3_bucket",
                    },
                },
                "commands": [
                    "bash %s/drone/notification_template.sh %s" % (GUI_TEST_DIR, NOTIFICATION_TEMPLATE_DIR),
                ],
            },
            {
                "name": "notification",
                "image": PLUGINS_SLACK,
                "settings": {
                    "webhook": from_secret("private_rocketchat"),
                    "channel": "desktop-internal",
                    "template": "file:%s/template.md" % NOTIFICATION_TEMPLATE_DIR,
                },
                "depends_on": ["create-template"],
            },
        ],
        "trigger": trigger,
        "depends_on": depends_on,
    }

def databaseService():
    service = {
        "name": "mysql",
        "image": MYSQL,
        "environment": {
            "MYSQL_USER": "owncloud",
            "MYSQL_PASSWORD": "owncloud",
            "MYSQL_DATABASE": "owncloud",
            "MYSQL_ROOT_PASSWORD": "owncloud",
        },
        "command": ["--default-authentication-plugin=mysql_native_password"],
    }
    return [service]

def installCore(version):
    stepDefinition = {
        "name": "install-core",
        "image": OC_CI_CORE,
        "settings": {
            "version": version,
            "core_path": "/drone/src/server",
            "db_type": "mysql",
            "db_name": "owncloud",
            "db_host": "mysql",
            "db_username": "owncloud",
            "db_password": "owncloud",
        },
    }
    return [stepDefinition]

def setupServerAndApp(logLevel):
    return [{
        "name": "setup-owncloud-server",
        "image": OC_CI_PHP % DEFAULT_PHP_VERSION,
        "commands": [
            "cd /drone/src/server/",
            "php occ a:e testing",
            "php occ config:system:set trusted_domains 1 --value=owncloud",
            "php occ log:manage --level %s" % logLevel,
            "php occ config:list",
            "php occ config:system:set skeletondirectory --value=/var/www/owncloud/server/apps/testing/data/tinySkeleton",
            "php occ config:system:set sharing.federation.allowHttpFallback --value=true --type=bool",
        ],
    }]

def owncloudService():
    return [{
        "name": "owncloud",
        "image": OC_CI_PHP % DEFAULT_PHP_VERSION,
        "environment": {
            "APACHE_WEBROOT": "/drone/src/server/",
            "APACHE_CONFIG_TEMPLATE": "ssl",
            "APACHE_SSL_CERT_CN": "server",
            "APACHE_SSL_CERT": "%s/%s.crt" % (dir["base"], "server"),
            "APACHE_SSL_KEY": "%s/%s.key" % (dir["base"], "server"),
            "APACHE_LOGGING_PATH": "/dev/null",
        },
        "commands": [
            "cat /etc/apache2/templates/base >> /etc/apache2/templates/ssl",
            "/usr/local/bin/apachectl -e debug -D FOREGROUND",
        ],
    }]

def testMiddlewareService():
    environment = {
        "BACKEND_HOST": "http://owncloud",
        "NODE_TLS_REJECT_UNAUTHORIZED": "0",
        "MIDDLEWARE_HOST": "testmiddleware",
        "REMOTE_UPLOAD_DIR": "/uploads",
    }

    return [{
        "name": "testmiddleware",
        "image": OC_TEST_MIDDLEWARE,
        "environment": environment,
        "volumes": [{
            "name": "uploads",
            "path": "/uploads",
        }],
    }]

def owncloudLog():
    return [{
        "name": "owncloud-log",
        "image": OC_UBUNTU,
        "detach": True,
        "commands": [
            "tail -f /drone/src/server/data/owncloud.log",
        ],
    }]

def fixPermissions():
    return [{
        "name": "fix-permissions",
        "image": OC_CI_PHP % DEFAULT_PHP_VERSION,
        "commands": [
            "cd /drone/src/server",
            "chown www-data * -R",
        ],
    }]

def setGuiTestReportDir():
    return [{
        "name": "create-gui-test-report-directory",
        "image": OC_UBUNTU,
        "commands": [
            "mkdir %s/screenshots -p" % GUI_TEST_REPORT_DIR,
            "chmod 777 %s -R" % GUI_TEST_REPORT_DIR,
        ],
    }]

def showGuiTestResult():
    return [{
        "name": "show-gui-test-result",
        "image": PYTHON,
        "commands": [
            "python /drone/src/test/gui/TestLogParser.py /drone/src/test/guiTestReport/results.json",
        ],
        "when": {
            "status": [
                "failure",
            ],
        },
    }]

def uploadGuiTestLogs():
    return [{
        "name": "upload-gui-test-result",
        "image": PLUGINS_S3,
        "settings": {
            "bucket": {
                "from_secret": "cache_public_s3_bucket",
            },
            "endpoint": {
                "from_secret": "cache_public_s3_server",
            },
            "path_style": True,
            "source": "%s/**/*" % GUI_TEST_REPORT_DIR,
            "strip_prefix": "%s" % GUI_TEST_REPORT_DIR,
            "target": "/${DRONE_REPO}/${DRONE_BUILD_NUMBER}/guiReportUpload",
        },
        "environment": {
            "AWS_ACCESS_KEY_ID": {
                "from_secret": "cache_public_s3_access_key",
            },
            "AWS_SECRET_ACCESS_KEY": {
                "from_secret": "cache_public_s3_secret_key",
            },
        },
        "when": {
            "status": [
                "failure",
            ],
        },
    }]

def buildGithubComment(suite):
    return [{
        "name": "build-github-comment",
        "image": OC_UBUNTU,
        "commands": [
            "bash /drone/src/test/gui/drone/comment.sh %s ${DRONE_REPO} ${DRONE_BUILD_NUMBER}" % GUI_TEST_REPORT_DIR,
        ],
        "environment": {
            "TEST_CONTEXT": suite,
            "CACHE_ENDPOINT": {
                "from_secret": "cache_public_s3_server",
            },
            "CACHE_BUCKET": {
                "from_secret": "cache_public_s3_bucket",
            },
        },
        "when": {
            "status": [
                "failure",
            ],
            "event": [
                "pull_request",
            ],
        },
    }]

def githubComment(alternateSuiteName):
    prefix = "Results for <strong>%s</strong> ${DRONE_BUILD_LINK}/${DRONE_JOB_NUMBER}${DRONE_STAGE_NUMBER}/1" % alternateSuiteName
    return [{
        "name": "github-comment",
        "image": THEGEEKLAB_DRONE_GITHUB_COMMENT,
        "settings": {
            "message": "%s/comments.file" % GUI_TEST_REPORT_DIR,
            "key": "pr-${DRONE_PULL_REQUEST}",
            "update": "true",
            "api_key": {
                "from_secret": "github_token",
            },
        },
        "commands": [
            "if [ -s %s/comments.file ]; then echo '%s' | cat - %s/comments.file > temp && mv temp %s/comments.file && /bin/drone-github-comment; fi" % (GUI_TEST_REPORT_DIR, prefix, GUI_TEST_REPORT_DIR, GUI_TEST_REPORT_DIR),
        ],
        "when": {
            "status": [
                "failure",
            ],
            "event": [
                "pull_request",
            ],
        },
    }]

def cancelPreviousBuilds():
    return {
        "kind": "pipeline",
        "type": "docker",
        "name": "cancel-previous-builds",
        "clone": {
            "disable": True,
        },
        "steps": [{
            "name": "cancel-previous-builds",
            "image": OC_CI_DRONE_CANCEL_PREVIOUS_BUILDS,
            "settings": {
                "DRONE_TOKEN": {
                    "from_secret": "drone_token",
                },
            },
        }],
        "trigger": {
            "ref": [
                "refs/pull/**",
            ],
        },
    }

def skipIfUnchanged(ctx, type):
    if ("full-ci" in ctx.build.title.lower()):
        return []

    base = [
        "^.github/.*",
        "^.vscode/.*",
        "^changelog/.*",
        "README.md",
        ".gitignore",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "COPYING",
        "COPYING.documentation",
    ]

    skip = []
    if type == "unit-tests":
        skip = base + [
            "^test/gui/.*",
        ]

    if type == "gui-tests":
        skip = base + [
            "^test/([^g]|g[^u]|gu[^i]).*",
        ]

    return [{
        "name": "skip-if-unchanged",
        "image": OC_CI_DRONE_SKIP_PIPELINE,
        "settings": {
            "ALLOW_SKIP_CHANGED": skip,
        },
        "when": {
            "event": [
                "pull_request",
            ],
        },
    }]
