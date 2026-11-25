// SmartTunes CI/CD pipeline (Three Dog).
// GitHub -> build on the jenkins EC2 -> test on the test EC2 -> canary release on the prod EC2.
//
// Jenkins credentials used (IDs must match):
//   dockerhub           Username/password: Docker Hub user + token (from AWS Secrets Manager)
//   ec2-ssh             SSH username (ubuntu) + private key (three-dog-key.pem)
//   smarttunes-test-env Secret file: app settings for the test environment (test DB + test bucket)

pipeline {
    agent none

    options {
        disableConcurrentBuilds()              // one release at a time
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    // Level 4: check GitHub for new commits every ~2 minutes and run automatically.
    triggers { pollSCM('H/2 * * * *') }

    parameters {
        booleanParam(name: 'FAIL_TESTS', defaultValue: false,
            description: 'Demo: add a failing test to show that the release is blocked')
        booleanParam(name: 'SIMULATE_CANARY_FAILURE', defaultValue: false,
            description: 'Demo: fail the first canary gate to show automatic rollback')
        string(name: 'CANARY_STAGES', defaultValue: '10 100',
            description: 'Canary traffic percentages, in order (last must be 100)')
    }

    environment {
        DOCKERHUB_REPO = 'CHANGE_ME_DOCKERHUB_USER/smarttunes'   // <-- your Docker Hub repo
        PROD_HOST      = 'CHANGE_ME_PROD_PRIVATE_IP'            // <-- prod EC2 private IP
    }

    stages {
        stage('Build') {
            agent { label 'built-in' }
            steps {
                script {
                    // The short commit SHA is the image tag: every image traces back to one commit.
                    env.GIT_SHA = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()
                    env.IMAGE_TAG = "${env.DOCKERHUB_REPO}:${env.GIT_SHA}"
                }
                // Fail fast on PHP syntax errors before spending time on the image.
                sh '''
                    docker run --rm -v "$PWD:/src:ro" php:8.3-cli \
                        sh -c 'find /src/app /src/docker -name "*.php" -print0 | xargs -0 -n1 php -l > /dev/null'
                '''
                sh 'docker build -f docker/Dockerfile --build-arg APP_VERSION="$GIT_SHA" -t "$IMAGE_TAG" .'
            }
        }

        stage('Push') {
            agent { label 'built-in' }
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub',
                        usernameVariable: 'DH_USER', passwordVariable: 'DH_TOKEN')]) {
                    sh '''
                        echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin
                        docker push "$IMAGE_TAG"
                        docker logout
                    '''
                }
                script {
                    // The digest is the image's content hash: test and prod run exactly this.
                    env.IMAGE_DIGEST = sh(returnStdout: true,
                        script: 'docker inspect --format "{{index .RepoDigests 0}}" "$IMAGE_TAG"').trim()
                }
                echo "Built ${env.IMAGE_TAG} -> ${env.IMAGE_DIGEST}"
            }
        }

        stage('Test') {
            agent { label 'test' }
            steps {
                withCredentials([file(credentialsId: 'smarttunes-test-env', variable: 'TEST_ENV')]) {
                    sh '''
                        docker rm -f smarttunes-test > /dev/null 2>&1 || true
                        docker run -d --name smarttunes-test --env-file "$TEST_ENV" \
                            -p 18080:80 "$IMAGE_DIGEST"
                        # Wait for the container (and its database connection) to be ready.
                        for i in $(seq 1 30); do
                            curl -fsS http://localhost:18080/healthz.php > /dev/null 2>&1 && break
                            sleep 2
                        done
                        chmod +x tests/smoke.sh
                        EXPECTED_VERSION="$GIT_SHA" FAIL_TESTS="$FAIL_TESTS" \
                            tests/smoke.sh http://localhost:18080
                    '''
                }
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'tests/results/*.xml'
                    sh 'docker logs smarttunes-test > test-container.log 2>&1 || true'
                    archiveArtifacts artifacts: 'test-container.log', allowEmptyArchive: true
                    sh 'docker rm -f smarttunes-test > /dev/null 2>&1 || true'
                }
            }
        }

        stage('Deploy (canary)') {
            agent { label 'built-in' }
            steps {
                withCredentials([sshUserPrivateKey(credentialsId: 'ec2-ssh',
                        keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                    sh '''
                        SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new"
                        ssh $SSH_OPTS "$SSH_USER@$PROD_HOST" "mkdir -p /opt/smarttunes"
                        # Ship the versioned deployment files with every release.
                        scp $SSH_OPTS -r deploy/docker-compose.yml deploy/nginx deploy/scripts \
                            "$SSH_USER@$PROD_HOST:/opt/smarttunes/"
                        ssh $SSH_OPTS "$SSH_USER@$PROD_HOST" \
                            "STAGES='$CANARY_STAGES' SIMULATE_FAILURE='$SIMULATE_CANARY_FAILURE' \
                             bash /opt/smarttunes/scripts/deploy.sh '$IMAGE_DIGEST' '$GIT_SHA'"
                    '''
                }
            }
        }
    }

    post {
        success { echo "Released ${env.GIT_SHA} (${env.IMAGE_DIGEST})" }
        failure { echo "Pipeline failed: production unchanged or rolled back to stable" }
    }
}
