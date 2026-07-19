pipeline {
    agent { label 'linux-worker' }

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timestamps()
    }

    parameters {
        booleanParam(
            name: 'RUN_ISSUANCE_TEST',
            defaultValue: false,
            description: 'Actually run issue-local-cert.sh against a throwaway test domain (writes a real cert and Nginx site on the worker, then cleans up).'
        )
    }

    environment {
        TEST_DOMAIN = 'jenkins-ci-test.local'
        TEST_PROXY  = 'http://127.0.0.1:9999'
    }

    stages {
        stage('Install Prerequisites') {
            steps {
                // Idempotent: installs openssl/nginx/shellcheck and bootstraps
                // a local CA on this worker if one doesn't already exist.
                // Fully self-contained — no scripts need to exist on the worker
                // ahead of time, just root access via sudo.
                sh '''
                    set -e
                    sudo apt-get update
                    sudo apt-get install -y openssl nginx shellcheck

                    sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

                    if [ ! -f /etc/local-ca/rootCA.crt ]; then
                        echo "No local CA found - generating one for this worker."
                        sudo mkdir -p /etc/local-ca/private
                        sudo chmod 700 /etc/local-ca/private
                        sudo openssl genrsa -out /etc/local-ca/private/rootCA.key 4096
                        sudo openssl req -x509 -new -nodes \\
                            -key /etc/local-ca/private/rootCA.key \\
                            -sha256 -days 3650 \\
                            -out /etc/local-ca/rootCA.crt \\
                            -subj "/C=US/ST=Homelab/O=Slade Services/CN=Homelab Local CA"
                    else
                        echo "Local CA already present - skipping generation."
                    fi
                '''
            }
        }

        stage('Set Permissions') {
            steps {
                sh 'chmod +x issue-local-cert.sh'
            }
        }

        stage('Lint') {
            steps {
                sh '''
                    bash -n issue-local-cert.sh
                    shellcheck issue-local-cert.sh
                '''
            }
        }

        stage('Smoke Test') {
            steps {
                // Non-destructive: just confirms the script runs and prints usage.
                sh 'sudo "$WORKSPACE/issue-local-cert.sh" --help'
            }
        }

        stage('Issuance Test') {
            when {
                expression { return params.RUN_ISSUANCE_TEST }
            }
            steps {
                sh 'sudo "$WORKSPACE/issue-local-cert.sh" -d "$TEST_DOMAIN" -p "$TEST_PROXY"'
            }
            post {
                always {
                    sh '''
                        sudo rm -rf "/etc/local-ca/issued/$TEST_DOMAIN"
                        sudo rm -f "/etc/nginx/sites-available/$TEST_DOMAIN" "/etc/nginx/sites-enabled/$TEST_DOMAIN"
                        sudo nginx -t
                        sudo systemctl reload nginx
                    '''
                }
            }
        }
    }

    post {
        failure {
            echo 'Build failed — check the Lint or Smoke Test stage output above for the specific error.'
        }
    }
}
