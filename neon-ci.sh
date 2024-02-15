# !/bin/bash

# Neon defaults
default_database_name="neondb"
default_suspend_timeout="0"

function help {
    echo "
    
    Usage: $0 <command> [options]

    Commands:
        create-branch
            --app-id <app-id>
            --neon-project-id <project-id>
            --parent-branch-id <parent-branch-id>
            --api-key-param <api-key-param>
            --role-name <role-name>
            --database-name <database-name>
            --suspend-timeout <suspend-timeout>
        
        cleanup-branches
            --app-id <app-id>
            --neon-project-id <project-id>
            --api-key-param <api-key-param>
           
"
}


function neon_ci_main {
    if [[ $# -lt 1 ]]; then
        help
        exit 1
    fi

    command=$1
    shift

    case $command in
        create-branch)
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --app-id)
                        AMPLIFY_APP_ID=$2
                        shift
                        shift
                        ;;
                    --neon-project-id)
                        NEON_PROJECT_ID=$2
                        shift
                        shift
                        ;;
                    --branch-name)
                        NEON_NEW_BRANCH_NAME=$2
                        shift
                        shift
                        ;;
                    --parent-branch)
                        NEON_PARENT_BRANCH=$2
                        shift
                        shift
                        ;;
                    --api-key-param)
                        NEON_API_KEY_PARAM=$2
                        shift
                        shift
                        ;;
                    --role-name)
                        NEON_ROLE_NAME=$2
                        shift
                        shift
                        ;;
                    --database-name)
                        NEON_DATABASE_NAME=${2:-$default_database_name}
                        shift
                        shift
                        ;;
                    --suspend-timeout)
                        NEON_SUSPEND_TIMEOUT=${2:-$default_suspend_timeout}
                        shift
                        shift
                        ;;
                    *)
                        echo "Unknown parameter: $1"
                        exit 1
                        ;;
                esac
            done
           
            # install_neonctl
            set_neon_api_key
            create_neon_branch
            
            ;;

        cleanup-branches)
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --app-id)
                        AMPLIFY_APP_ID=$2
                        shift
                        shift
                        ;;
                    --neon-project-id)
                        NEON_PROJECT_ID=$2
                        shift
                        shift
                        ;;
                    --api-key-param)
                        NEON_API_KEY_PARAM=$2
                        shift
                        shift
                        ;;
                    *)
                        echo "Unknown parameter: $1"
                        exit 1
                        ;;
                esac
            done

            # install_neonctl
            set_neon_api_key
            cleanup_branches

            ;;
        *)
            echo "Unknown command: $command"
            exit 1
            ;;
    esac
}


# read the key from SSM Parameter Store
# and export it as an environment variable
function set_neon_api_key {
    export NEON_API_KEY=$(aws ssm get-parameter --name $NEON_API_KEY_PARAM --with-decryption --query Parameter.Value --output text)
    if [[ -z "${NEON_API_KEY}" ]]; then
        echo "ERROR: NEON_API_KEY is not set. Exiting."
        exit 1
    fi
}

# function install_neonctl {
#     if ! command neonctl --v &> /dev/null; then
#         if [ -f "yarn.lock" ]; then
#             yarn global add neonctl@v1
#         elif [ -f "pnpm-lock.yaml" ]; then
#             pnpm setup
#             pnpm install -g neonctl@v1
#         else
#             npm install -g neonctl@v1
#         fi
#     fi
# }

# create a new database branch
# 0 means default = 5min
function create_neon_branch {

    branch_name="${AMPLIFY_APP_ID}-${NEON_NEW_BRANCH_NAME}"

    neonctl branches create \
        --project-id $NEON_PROJECT_ID \
        --name $branch_name \
        --suspend_timeout $NEON_SUSPEND_TIMEOUT \
        $(if [[ -n "$NEON_PARENT_BRANCH" ]]; then echo "--parent $NEON_PARENT_BRANCH"; fi) \
        --output json \
            2> branch_err > branch_out || true
 
    if [[ -f branch_out ]]; then
        cat branch_out | jq '.connection_uris[0].connection_parameters.password = "********"'
        echo "branch create out:"
        cat branch_out
    fi
    
    if [[ -f branch_err ]]; then
        echo "branch create err:"
        cat branch_err
    fi

    if [[ $(cat branch_err) == *"already exists"* ]]; then
        # Get the branch id by its name. We list all branches and filter by name
        branch_id=$(neonctl branches list --project-id $NEON_PROJECT_ID -o json \
            | jq -r ".[] | select(.name == \"${branch_name}\") | .id")

        echo "branch exists, branch id: ${branch_id}, branch name: ${branch_name}"

        NEON_CONNECTION_STRING=$(neonctl cs ${branch_id} --project-id $NEON_PROJECT_ID --role-name $NEON_ROLE_NAME --database-name $NEON_DATABASE_NAME --pooled --extended -o json | jq -r '.connection_string')
        echo -e "\nDATABASE_URL=${NEON_CONNECTION_STRING}" >> .env

    elif [[ $(cat branch_err) == *"ERROR:"* ]]; then
        echo "ERROR: branch creation failed"
        cat branch_err
        exit 1
    else
        branch_id=$(cat branch_out | jq --raw-output '.branch.id')
        
        if [[ -z "${branch_id}" ]]; then
            echo "ERROR: didn't get the branch id"
            exit 1
        fi

        echo "branch created, new branch id: ${branch_id}"

        NEON_CONNECTION_STRING=$(neonctl cs ${branch_id} --project-id $NEON_PROJECT_ID --role-name $NEON_ROLE_NAME --database-name $NEON_DATABASE_NAME --pooled --extended -o json | jq -r '.connection_string')

        echo -e "\nDATABASE_URL=${NEON_CONNECTION_STRING}" >> .env
    fi
}


function cleanup_branches {
    app_branches=$(aws amplify list-branches --app-id "$AMPLIFY_APP_ID" --query 'branches[].branchName' --output json)

   # add the ${AMPLIFY_APP_ID} prefix to the branch names
    prefixed_app_branches=$(echo "$app_branches" | jq -r ".[] | \"${AMPLIFY_APP_ID}-\" + ." | tr '\n' ' ')

    neon_branches=$(neonctl branches list --project-id $NEON_PROJECT_ID --output json | jq -r '.[].name')

    if [[ -z "${prefixed_app_branches}" ]]; then
        echo "ERROR: neon branches are not set"
        return
    fi

    for branch in $neon_branches; do
        # skip if main or dev app branch
        # we don't want to delete the main and dev branches
        if [[ $branch == "${AMPLIFY_APP_ID}-main" || $branch == "${AMPLIFY_APP_ID}-dev" || $branch == "main" || $branch == "dev" ]]; then
            echo "skipping branch: $branch"
            continue
        fi

        echo "App branches (prefixed with app-id): $prefixed_app_branches"

        if [[ ! "$prefixed_app_branches" =~ "$branch" ]] && [[ -n "$branch" ]]; then
            echo "Deleting Neon branch: $branch"
            neonctl branches delete --project-id $NEON_PROJECT_ID $branch
        fi
    done
}



# main
neon_ci_main $@
