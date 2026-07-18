pipeline {
    agent { label 'linux worker' }

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
                // See README.md > Continuous Integration for the script contents.
                sh 'sudo /usr/local/bin/jenkins-nginx-cert-prereqs.sh'
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
                    sh 'sudo /usr/local/bin/jenkins-nginx-cert-cleanup.sh "$TEST_DOMAIN"'
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
