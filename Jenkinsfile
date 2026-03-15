pipeline {
    agent any

    stages {
        stage('Checkout') {
            steps {
                checkout scm   // this automatically uses the repo/branch/credentials from the job config
            }
        }

        stage('Verify') {
            steps {
                sh 'ls -la'                  // shows all files in your repo
                sh 'pwd'                     // shows current working directory
                sh 'git log -1 --pretty=%B'  // shows the latest commit message
            }
        }
    }
}