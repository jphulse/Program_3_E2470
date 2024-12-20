class Api::V1::GradesController < ApplicationController
  include AuthorizationHelper
  # Determines if the current user is able to perform :action as specified by the path parameter
  # If the user has the role of TA or higher they are granted access to all operations beyond view_team
  # Uses a switch statement for easy maintainability if added functionality is ever needed for students or
  # additional roles, to add more functionality simply add additional switch cases in the same syntax with
  # case 'action' and then some boolean check determining if that is allowed or forbidden.
  # GET /api/v1/grades/:action/action_allowed
  def action_allowed
    permitted = case params[:action]
                when 'view_team'
                  view_team_allowed?
                else
                  current_user_has_ta_privileges?
                end
    render json: { allowed: permitted }, status: permitted ? :ok : :forbidden
  end

  # Provides the needed functionality of querying needed values from the backend db and returning them to build the
  # heat map in the frontend from the TA/staff view.  These values are set in the get_data_for_heat_map method
  # which takes the assignment id as a parameter.
  # GET /api/v1/grades/:id/view
  def view
    get_data_for_heat_map(params[:id])
    render json: { scores: @scores[:participants], assignment: @assignment, averages: @averages,
                   avg_of_avg: @avg_of_avg, review_score_count: @review_score_count }, status: :ok
  end

  # Provides all relevant data for the student perspective for the heat map page as well as the
  # needed information to showcase the questionnaires from the student view.  Additionally, handles the removal of user
  # identification in the reviews within the hide_reviewers_rom_student method.
  # GET /api/v1/grades/:id/view_team
  def view_team
    get_data_for_heat_map(params[:id])
    @scores[:participants] = hide_reviewers_from_student
    questionnaires = @assignment.questionnaires
    questions = retrieve_questions(questionnaires, @assignment.id)
    render json: {scores: @scores[:participants], assignment: @assignment, averages: @averages, avg_of_avg: @avg_of_avg,
                  review_score_count: @review_score_count, questions: questions }, status: :ok
  end

  # Sets information required for editing the grade information, this includes the participant, questions, scores, and
  # assignment. The participant is the student who's grade is being modified.  The assignment is the assignment where
  # the grade for that participant is currently being examined.  The questions are the list of questions or rubric items
  # associated with this assignment.  Then the scores is the aggregation of the participant scoring information and team
  # scoring information which is needed for view in the frontend.
  # GET /api/v1/grades/:id/edit
  def edit
    begin
      participant = AssignmentParticipant.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: {message: "Assignment participant #{params[:id]} not found"}, status: :not_found
      return
    end
    assignment = participant.assignment
    questions = list_questions(assignment)
    scores = review_grades(assignment, questions)
    render json: {participant: participant, questions: questions, scores: scores, assignment: assignment}, status: :ok
  end

  # Provides functionality that handles informing the frontend which controller and action to direct to for instructor
  # review given the current state of the system. The intended controller to handle the creation or editing of a review
  # is the response controller, however this method just determines if a new review must be made based on figuring out
  # whether or not an associated review_mapping exists from the participant already.  If one does they should go to
  # Response#edit and if one does not they should go to Response#new. This goal is achieved by locating the review_
  # mapping associated with this participant and then utilizing the new record functionality in order to determine
  # which action is appropriate.  If the review_mapping is new then a new response needs to be created and if it is not
  # then the previous response can be edited instead.  All of this will be handled within the Response Controller's
  # response#new and response#edit functionality. Only ever returns a status of ok.
  # GET /api/v1/grades/:id/instructor_review
  def instructor_review
    begin
      participant = AssignmentParticipant.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { message: "Assignment participant #{params[:id]} not found" }, status: :not_found
      return
    end
    review_mapping = find_participant_review_mapping(participant)
    if review_mapping.new_record?
      render json: { controller: 'response', action: 'new', id: review_mapping.map_id,
                     return: 'instructor'}, status: :ok
    else
      review = Response.find_by(map_id: review_mapping.map_id)
      render json: { controller: 'response', action: 'edit', id: review.id, return: 'instructor'}, status: :ok
    end
  end

  # Update method for the grade associated with a team, allows an instructor to upgrade a team's grade with a grade
  # and a comment on their assignment for submission.  The team is then saved with this change in order to be accessed
  # elsewhere in the code for needed scoring evaluations.  If a failure occurs while saving the team then this will
  # return a bad_request response complete with a message and the global ERROR_INFO which can be set elsewhere for
  # further error handling mechanisms
  # PATCH /api/v1/grades/:participant_id/update/:grade_for_submission
  def update
    participant = AssignmentParticipant.find_by(id: params[:participant_id])

    team = participant.team
    team.grade_for_submission = params[:grade_for_submission]
    team.comment_for_submission = params[:comment_for_submission]
    begin
      team.save
    rescue StandardError => e
      render json: {message: "Error occurred while updating grade for team #{team.id}",
                    error: e.message }, status: :bad_request
      return
    end
    render json: { controller: 'grades', action: 'view_team', id: participant.id}, status: :ok
  end

  private

  # This method is used from edit methods
  # Finds all questions in all relevant questionnaires associated with this assignment
  def list_questions(assignment)
    questions = {}
    questionnaires = assignment.questionnaires
    questionnaires.each do |questionnaire|
      questions[questionnaire.id.to_s.to_sym] = questionnaire.questions
    end
    questions
  end

  # Helper method to determine if a user can perform the view_team action, meaning they are the participant making this
  # request
  def view_team_allowed?
    if current_user_has_student_privileges? # students can only see the heat map for their own team
      participant = AssignmentParticipant.find(params[:id])
      participant.user_id == session[:user_id]
    else
      true
    end
  end

  # Checks if the rubric varies by round and then returns appropriate
  # questions based on the ruling
  def filter_questionnaires(assignment)
    questionnaires = assignment.questionnaires
    if assignment.varying_rubrics_by_round?
      retrieve_questions(questionnaires, assignment.id)
    else
      questions = {}
      questionnaires.each do |questionnaire|
        questions[questionnaire.id.to_s.to_sym] = questionnaire.questions
      end
      questions
    end
  end

  # Gets all of the review grades and formats the score appropriately based on those scores for use in the controller
  # Primarily serves to gather information for the heat maps and editing.
  def review_grades(assignment, questions)
    scores = { participants: {}, teams: {} }

    # Participant scores
    assignment.participants.each do |participant|
      participant_scores = participant.participant_scores.where(assignment: assignment).map do |score_record|
        {
          question_id: score_record.question_id,
          score: score_record.score,
          total_score: score_record.total_score,
          round: score_record.round,
          question: questions.values.flatten.find { |q| q.id == score_record.question_id }
        }
      end
      # Chat GPT Assisted
      scores[:participants][participant.id.to_s.to_sym] = participant_scores

      # Team scores
      team = participant.user.teams.find_by(assignment: assignment)
      next unless team

      team_id = team.id.to_s.to_sym
      scores[:teams][team_id] ||= 0

      # Calculate average score for the team
      team_scores = participant_scores.map { |s| s[:score].to_f / s[:total_score] * 100 }
      scores[:teams][team_id] = team_scores.sum / team_scores.size
    end

    scores
  end

  # from a given participant we find or create an AsssignmentParticipant to review the team of that participant, and set
  # the handle if it is a new record.  Then using this information we locate or create a ReviewResponseMap in order to
  # facilitate the response
  def find_participant_review_mapping(participant)
    reviewer = AssignmentParticipant.find_or_create_by(user_id: session[:user].id, parent_id: participant.assignment.id)
    reviewer.set_handle if reviewer.new_record?
    reviewee = participant.team
    ReviewResponseMap.find_or_create_by(reviewee_id: reviewee.id, reviewer_id: reviewer.id,
                                        reviewed_object_id: participant.assignment.id)
  end

  # Filters out the nil scores contained within the hash and returns a map with them converted to integers for
  # operations
  def filter_scores(team_scores)
    team_scores
      .compact
      .map { |team| team.is_a?(Array) ? team[1].to_i : team.to_i }
  end

  # Provides a float representing the average of the array with error handling
  def mean(array)
    return 0 if array.nil? || array.empty?
    array.sum / array.length.to_f
  end

  # Provides data for the heat maps in the view statements
  def get_data_for_heat_map(id)
    # Finds the assignment
    @assignment = Assignment.find(id)
    # Extracts the questionnaires
    @questions = filter_questionnaires(@assignment)
    @scores = review_grades(@assignment, @questions)
    @review_score_count = @scores[:participants].length # After rejecting nil scores need original length to iterate over hash
    @averages = filter_scores(@scores[:teams])
    @avg_of_avg = mean(@averages)
  end

  # Loop to hide reviewer information from the student view of the heat map that is implemented in view_team
  # ChatGPT Assisted
  def hide_reviewers_from_student
    @scores[:participants].each_with_index.map do |(_, value), index|
      ["reviewer_#{index}".to_sym, value]
    end.to_h
  end
end

# Retrieves all of the relevant questions associated with each questionnaire and round of the assignment
def retrieve_questions(questionnaires, assignment_id)
  questions = {}
  questionnaires.each do |questionnaire|
    round = AssignmentQuestionnaire.where(assignment_id: assignment_id,
                                          questionnaire_id: questionnaire.id).first&.used_in_round
    questionnaire_symbol = if round.nil?
                             questionnaire.id.to_s.to_sym
                           else
                             (questionnaire.id.to_s + round.to_s).to_sym
                           end
    questions[questionnaire_symbol] = questionnaire.questions
  end
  questions
end

