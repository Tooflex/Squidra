DO $$
DECLARE actor uuid; entity uuid; event uuid; seq bigint; run uuid;
    frame uuid; camera uuid; epoch uuid; watch uuid; request uuid; thread uuid; domain uuid; journal uuid;
BEGIN
FOREACH actor IN ARRAY ARRAY['00000000-0000-0000-0000-000000000001'::uuid,'00000000-0000-0000-0000-000000000002'::uuid] LOOP
    SELECT id INTO entity FROM world_entities WHERE actor_id=actor LIMIT 1;
    IF NOT EXISTS(SELECT 1 FROM world_events WHERE actor_id=actor) THEN
        INSERT INTO world_events(event_id,actor_id,stream_id,stream_version,idempotency_key,entity_ids,event_type,observed_at,source_id,confidence,payload_version,payload,correlation_id)
        VALUES(gen_random_uuid(),actor,gen_random_uuid(),1,'fixture',ARRAY[entity],'fixture',now(),'fixture',1,1,'{}',gen_random_uuid());
    END IF;
    IF NOT EXISTS(SELECT 1 FROM coordinate_frames WHERE actor_id=actor) THEN
        INSERT INTO coordinate_frames VALUES(gen_random_uuid(),actor,'fixture',3,'metres','{}');
    END IF;
    SELECT event_id,sequence INTO event,seq FROM world_events WHERE actor_id=actor LIMIT 1;
    SELECT id INTO frame FROM coordinate_frames WHERE actor_id=actor LIMIT 1;
    SELECT id INTO run FROM agent_runs WHERE actor_id=actor LIMIT 1;
    camera:=gen_random_uuid();epoch:=gen_random_uuid();watch:=gen_random_uuid();request:=gen_random_uuid();thread:=gen_random_uuid();domain:=gen_random_uuid();journal:=gen_random_uuid();
    INSERT INTO entity_associations VALUES(actor,camera,1,1,jsonb_build_object('schemaVersion',1,'revision',1,'actorID',actor,'cameraID',camera));
    INSERT INTO movement_epochs VALUES(actor,epoch,entity,jsonb_build_object('version',1,'actor',actor,'entity',entity,'epoch',epoch));
    INSERT INTO watch_intentions VALUES(watch,actor,entity,'fixture',0,'active');
    INSERT INTO watch_notifications VALUES(actor,watch,event,event);
    INSERT INTO watch_dispatch_cursors VALUES(actor,seq);
    INSERT INTO retained_media(actor_id,frame_id,captured_us,expires_us,media_type,byte_count,blob) VALUES(actor,frame,0,1000000,'image/png',2,decode('01ff','hex'));
    INSERT INTO run_event_streams(run_id,actor_id,thread_id,request_id,retention_seconds,created_at,expires_at) VALUES(run,actor,thread,request,60,now(),now()+interval '1 minute');
    INSERT INTO run_events VALUES(actor,run,1,'RUN_STARTED',jsonb_build_object('type','RUN_STARTED','runId',run));
    INSERT INTO read_run_tasks VALUES(actor,run,thread,request,'{"private":"fixture-canary"}');
    INSERT INTO read_run_completions VALUES(actor,run,request,1,decode('0102','hex'));
    INSERT INTO read_run_plans VALUES(actor,run,request,1,decode('0102','hex'));
    INSERT INTO read_run_tool_results VALUES(actor,run,request,gen_random_uuid(),1,repeat('a',64),'fixture',decode('0102','hex'));
    INSERT INTO read_run_answers VALUES(actor,run,request,1,decode('0102','hex'));
    INSERT INTO read_run_local_domains VALUES(actor,domain,'1:2');
    INSERT INTO read_run_owners VALUES(actor,run,domain,'1:2',gen_random_uuid());
    INSERT INTO consolidation_journals VALUES(actor,journal,0,jsonb_build_object('schemaVersion',1,'actorID',actor,'id',journal,'commands','[]'::jsonb)::text);
END LOOP;
END $$;
